const std = @import("std");
const types = @import("types.zig");
const fsutils = @import("fsutils.zig");

/// Current manifest schema version.
pub const ManifestVersion: u32 = 2;

/// Metadata captured for a generated repository build.
pub const RepoManifest = struct {
    version: u32 = ManifestVersion,
    source: []const u8,
    output_subpath: []const u8,
    doc_tool: types.DocTool,
    doc_path: ?[]const u8 = null,
    ref_kind: ?types.RefKind = null,
    ref_value: ?[]const u8 = null,
    commit_short: ?[]const u8 = null,
    build_hash: u64 = 0,
};

/// Loaded manifest paired with its arena allocator.
pub const LoadedManifest = struct {
    arena: *std.heap.ArenaAllocator,
    value: RepoManifest,

    /// Release the arena allocator for the loaded manifest.
    pub fn deinit(self: *const LoadedManifest) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
    }
};

/// Load a manifest from disk if it exists.
pub fn load(allocator: types.Allocator, path: []const u8) !?LoadedManifest {
    if (!fsutils.fileExists(path)) return null;

    const data = try std.fs.cwd().readFileAlloc(allocator, path, 256 * 1024);
    defer allocator.free(data);

    const parsed = try std.json.parseFromSlice(RepoManifest, allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    return LoadedManifest{ .arena = parsed.arena, .value = parsed.value };
}

/// Save a manifest to disk as JSON.
pub fn save(path: []const u8, manifest: RepoManifest) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    var buffer: [1024]u8 = undefined;
    var writer = file.writer(&buffer);
    try std.json.Stringify.value(manifest, .{ .whitespace = .indent_2, .emit_null_optional_fields = true }, &writer.interface);
    try writer.interface.writeAll("\n");
    try writer.interface.flush();
}

/// Compare two manifests for field equality.
pub fn equals(a: RepoManifest, b: RepoManifest) bool {
    return a.version == b.version and
        std.mem.eql(u8, a.source, b.source) and
        std.mem.eql(u8, a.output_subpath, b.output_subpath) and
        a.doc_tool == b.doc_tool and
        optionalEq(a.doc_path, b.doc_path) and
        optionalEqRefKind(a.ref_kind, b.ref_kind) and
        optionalEq(a.ref_value, b.ref_value) and
        optionalEq(a.commit_short, b.commit_short) and
        a.build_hash == b.build_hash;
}

fn optionalEq(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn optionalEqRefKind(a: ?types.RefKind, b: ?types.RefKind) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}

/// Return the manifest directory path for a cache root.
pub fn manifestDir(allocator: types.Allocator, cache_dir: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ cache_dir, "manifest" });
}

/// Return the full manifest file path for a cache key.
pub fn manifestPath(allocator: types.Allocator, cache_dir: []const u8, key: []const u8) ![]const u8 {
    const dir = try manifestDir(allocator, cache_dir);
    defer allocator.free(dir);
    const filename = try std.mem.concat(allocator, u8, &.{ key, ".json" });
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ dir, filename });
}

test "manifest equality compares fields" {
    // covers: manifest.equals
    const base = RepoManifest{
        .source = "repo",
        .output_subpath = "repo",
        .doc_tool = .mkdocs,
        .doc_path = null,
        .ref_kind = null,
        .ref_value = null,
        .commit_short = null,
    };

    try std.testing.expect(equals(base, base));
    const other = RepoManifest{
        .source = "repo",
        .output_subpath = "repo",
        .doc_tool = .mkdocs,
        .doc_path = "docs",
        .ref_kind = null,
        .ref_value = null,
        .commit_short = null,
        .build_hash = 1,
    };
    try std.testing.expect(!equals(base, other));
}

test "manifest save and load roundtrip" {
    // covers: manifest.save manifest.load manifest.deinit manifest.manifestDir manifest.manifestPath
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const cache_dir = try std.fs.path.join(std.testing.allocator, &.{ base, "cache" });
    defer std.testing.allocator.free(cache_dir);
    try tmp.dir.makePath("cache");

    const dir_path = try manifestDir(std.testing.allocator, cache_dir);
    defer std.testing.allocator.free(dir_path);
    const file_path = try manifestPath(std.testing.allocator, cache_dir, "repo");
    defer std.testing.allocator.free(file_path);
    try fsutils.ensureDir(dir_path);

    const manifest = RepoManifest{
        .source = "repo",
        .output_subpath = "repo",
        .doc_tool = .mkdocs,
        .doc_path = "docs",
        .ref_kind = .tag,
        .ref_value = "v1.0.0",
        .commit_short = "abc123",
        .build_hash = 42,
    };

    try save(file_path, manifest);
    const loaded_opt = try load(std.testing.allocator, file_path);
    try std.testing.expect(loaded_opt != null);
    var loaded = loaded_opt.?;
    defer loaded.deinit();
    try std.testing.expectEqualStrings("repo", loaded.value.source);
    try std.testing.expectEqualStrings("docs", loaded.value.doc_path.?);
    try std.testing.expectEqual(@as(u64, 42), loaded.value.build_hash);
    try std.testing.expect(std.mem.endsWith(u8, dir_path, "cache/manifest") or std.mem.endsWith(u8, dir_path, "cache\\manifest"));
    try std.testing.expect(std.mem.endsWith(u8, file_path, "repo.json"));
}
