//! Recursive discovery of local Git repositories and automatic documentation tool inference.

const std = @import("std");
const types = @import("types.zig");
const fsutils = @import("fsutils.zig");
const git = @import("git.zig");
const doc_tool = @import("doc_tool.zig");

/// Options controlling repository discovery.
pub const DiscoverOptions = struct {
    /// Root directory to begin scanning from.
    root: []const u8,
    /// Maximum directory recursion depth.
    max_depth: usize = 6,
    /// Whether to infer each repository's documentation tool during discovery.
    infer_tool: bool = true,
};

/// Discovered repository metadata.
pub const RepoHit = struct {
    /// Full path to the discovered repository.
    path: []const u8,
    /// Basename of the repository directory.
    name: []const u8,
    /// Inferred documentation tool, if detected.
    doc_tool: ?types.DocTool = null,
};

/// Queue item tracking a directory path and its recursion depth during breadth/depth-first scanning.
const ScanItem = struct {
    /// Owned directory path to scan.
    path: []const u8,
    /// Current depth from `options.root`.
    depth: usize,
};

/// Discover git repositories under `options.root` up to `options.max_depth`.
///
/// @param allocator Allocator for returned `RepoHit` slice and strings.
/// @param options Discovery options (`root`, `max_depth`, `infer_tool`).
/// @return Owned slice of `RepoHit` entries (`path` and `name` owned by caller).
pub fn discover(allocator: types.Allocator, options: DiscoverOptions) types.GenerateAllCodeDocsError![]RepoHit {
    const io = fsutils.defaultIo();
    var hits = std.ArrayList(RepoHit).empty;
    errdefer {
        for (hits.items) |hit| {
            allocator.free(hit.path);
            allocator.free(hit.name);
        }
        hits.deinit(allocator);
    }

    var stack = std.ArrayList(ScanItem).empty;
    defer {
        for (stack.items) |item| allocator.free(item.path);
        stack.deinit(allocator);
    }

    try stack.append(allocator, .{ .path = try allocator.dupe(u8, options.root), .depth = 0 });

    while (stack.items.len > 0) {
        const current = stack.pop().?;
        defer allocator.free(current.path);

        if (git.isGitRepo(current.path)) {
            const name = std.Io.Dir.path.basename(current.path);
            const tool: ?types.DocTool = if (options.infer_tool)
                doc_tool.infer(allocator, current.path) catch null
            else
                null;
            try hits.append(allocator, .{
                .path = try allocator.dupe(u8, current.path),
                .name = try allocator.dupe(u8, name),
                .doc_tool = tool,
            });
            continue;
        }

        if (current.depth >= options.max_depth) continue;

        var dir = std.Io.Dir.cwd().openDir(io, current.path, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            if (shouldSkip(entry.name)) continue;

            const next_path = try std.Io.Dir.path.join(allocator, &.{ current.path, entry.name });
            try stack.append(allocator, .{ .path = next_path, .depth = current.depth + 1 });
        }
    }

    return hits.toOwnedSlice(allocator);
}

/// Check if a directory name should be skipped during repository discovery.
///
/// @param name Directory basename.
/// @return `true` if `name` is an internal or build artifact directory.
fn shouldSkip(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, ".generate-all-code-docs") or
        std.mem.eql(u8, name, "zig-cache") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, "node_modules") or
        std.mem.eql(u8, name, ".venv") or
        std.mem.eql(u8, name, "dist") or
        std.mem.eql(u8, name, "build");
}

test "discover finds nested git repos, respects max_depth, skips build dirs, and handles infer_tool" {
    // covers: discover.discover discover.shouldSkip
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo1/.git");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo1/mkdocs.yml", .data = "site_name: r1\x0a" });
    try tmp.dir.createDirPath(std.testing.io, "nested/repo2/.git");
    try tmp.dir.createDirPath(std.testing.io, "node_modules/ignored_repo/.git");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "top_file.txt", .data = "ignore" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const repos = try discover(std.testing.allocator, .{ .root = root, .max_depth = 4, .infer_tool = true });
    defer {
        for (repos) |repo| {
            std.testing.allocator.free(repo.path);
            std.testing.allocator.free(repo.name);
        }
        std.testing.allocator.free(repos);
    }

    try std.testing.expectEqual(@as(usize, 2), repos.len);
    var saw_repo1 = false;
    var saw_repo2 = false;
    for (repos) |r| {
        if (std.mem.eql(u8, r.name, "repo1")) {
            saw_repo1 = true;
            try std.testing.expectEqual(@as(?types.DocTool, .mkdocs), r.doc_tool);
        }
        if (std.mem.eql(u8, r.name, "repo2")) {
            saw_repo2 = true;
            try std.testing.expectEqual(@as(?types.DocTool, null), r.doc_tool);
        }
    }
    try std.testing.expect(saw_repo1);
    try std.testing.expect(saw_repo2);

    // Depth 1 should only find repo1, not nested/repo2
    const shallow_repos = try discover(std.testing.allocator, .{ .root = root, .max_depth = 1, .infer_tool = false });
    defer {
        for (shallow_repos) |repo| {
            std.testing.allocator.free(repo.path);
            std.testing.allocator.free(repo.name);
        }
        std.testing.allocator.free(shallow_repos);
    }
    try std.testing.expectEqual(@as(usize, 1), shallow_repos.len);
    try std.testing.expectEqualStrings("repo1", shallow_repos[0].name);
    try std.testing.expectEqual(@as(?types.DocTool, null), shallow_repos[0].doc_tool);

    // Non-existent root is gracefully skipped
    const missing_root = try std.Io.Dir.path.join(std.testing.allocator, &.{ root, "missing" });
    defer std.testing.allocator.free(missing_root);
    const empty_repos = try discover(std.testing.allocator, .{ .root = missing_root });
    defer std.testing.allocator.free(empty_repos);
    try std.testing.expectEqual(@as(usize, 0), empty_repos.len);
}
