const std = @import("std");
const types = @import("types.zig");
const git = @import("git.zig");
const doc_tool = @import("doc_tool.zig");

/// Options controlling repository discovery.
pub const DiscoverOptions = struct {
    max_depth: usize = 6,
    infer_tool: bool = true,
};

/// Result entry for a discovered repository.
pub const RepoHit = struct {
    path: []const u8,
    name: []const u8,
    doc_tool: ?types.DocTool = null,
};

const ScanItem = struct {
    path: []const u8,
    depth: usize,
    owned: bool,
};

/// Recursively scan for git repositories under the root path.
pub fn discover(allocator: types.Allocator, root_path: []const u8, options: DiscoverOptions) ![]RepoHit {
    var repos = std.ArrayList(RepoHit).empty;
    errdefer {
        for (repos.items) |repo| {
            allocator.free(repo.path);
            allocator.free(repo.name);
        }
        repos.deinit(allocator);
    }

    var stack = std.ArrayList(ScanItem).empty;
    defer stack.deinit(allocator);

    const root_abs = try std.fs.cwd().realpathAlloc(allocator, root_path);
    defer allocator.free(root_abs);

    try stack.append(allocator, .{ .path = root_abs, .depth = 0, .owned = false });

    while (stack.pop()) |item| {
        defer if (item.owned) allocator.free(item.path);

        if (git.isGitRepo(allocator, item.path)) {
            const name = try allocator.dupe(u8, std.fs.path.basename(item.path));
            const path_copy = try allocator.dupe(u8, item.path);
            var inferred_tool: ?types.DocTool = null;
            if (options.infer_tool) {
                inferred_tool = doc_tool.infer(allocator, item.path) catch null;
            }
            try repos.append(allocator, .{ .path = path_copy, .name = name, .doc_tool = inferred_tool });
            continue;
        }

        if (item.depth >= options.max_depth) {
            continue;
        }

        var dir = std.fs.cwd().openDir(item.path, .{ .iterate = true }) catch continue;
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory) continue;
            if (shouldSkip(entry.name)) continue;

            const child = try std.fs.path.join(allocator, &.{ item.path, entry.name });
            try stack.append(allocator, .{ .path = child, .depth = item.depth + 1, .owned = true });
        }
    }

    return repos.toOwnedSlice(allocator);
}

fn shouldSkip(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, ".docforge") or
        std.mem.eql(u8, name, "zig-cache") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, "node_modules") or
        std.mem.eql(u8, name, ".venv") or
        std.mem.eql(u8, name, "dist") or
        std.mem.eql(u8, name, "build");
}

fn hasRepoNamed(items: []RepoHit, name: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.name, name)) return true;
    }
    return false;
}

test "discover finds git repos" {
    // covers: discover.discover
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("repo1/.git");
    try tmp.dir.makePath("org/repo2/.git");

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const repos = try discover(std.testing.allocator, root, .{ .max_depth = 4 });
    defer {
        for (repos) |repo| {
            std.testing.allocator.free(repo.path);
            std.testing.allocator.free(repo.name);
        }
        std.testing.allocator.free(repos);
    }

    try std.testing.expect(repos.len == 2);
    try std.testing.expect(hasRepoNamed(repos, "repo1"));
    try std.testing.expect(hasRepoNamed(repos, "repo2"));
}
