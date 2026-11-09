//! Incremental build manifest persistence, comparison, and cache path resolution.

const std = @import("std");
const types = @import("types.zig");
const fsutils = @import("fsutils.zig");

/// Current manifest schema version.
pub const ManifestVersion: u32 = 2;

/// Metadata captured for a generated repository build.
pub const RepoManifest = struct {
    /// Schema version number.
    version: u32 = ManifestVersion,
    /// Original repository source string.
    source: []const u8,
    /// Normalized output subpath under the site root.
    output_subpath: []const u8,
    /// Documentation tool used for the build.
    doc_tool: types.DocTool,
    /// Resolved tool documentation path, if any.
    doc_path: ?[]const u8 = null,
    /// Checked-out reference kind, if any.
    ref_kind: ?types.RefKind = null,
    /// Checked-out reference value, if any.
    ref_value: ?[]const u8 = null,
    /// Short commit hash, if any.
    commit_short: ?[]const u8 = null,
    /// Wyhash fingerprint of build options, templates, filters, and hooks.
    build_hash: u64 = 0,
};

/// Loaded manifest paired with its `std.json.Parsed` arena wrapper.
pub const LoadedManifest = struct {
    /// Parsed JSON wrapper owning the arena allocator.
    parsed: std.json.Parsed(RepoManifest),
    /// Parsed `RepoManifest` value.
    value: RepoManifest,

    /// Release the JSON arena allocator for the loaded manifest.
    ///
    /// @param self Pointer to the `LoadedManifest` to deinitialize.
    pub fn deinit(self: *const LoadedManifest) void {
        self.parsed.deinit();
    }
};

/// Load a manifest from disk if `path` exists.
///
/// @param allocator Backing allocator for reading the file and parsing JSON.
/// @param path Filesystem path to the manifest JSON file.
/// @return `LoadedManifest` if the file exists, or `null` if absent.
pub fn load(allocator: types.Allocator, path: []const u8) types.GenerateAllCodeDocsError!?LoadedManifest {
    if (!fsutils.fileExists(path)) return null;

    const io = fsutils.defaultIo();
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(256 * 1024));
    defer allocator.free(data);

    const parsed = try std.json.parseFromSlice(RepoManifest, allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    return LoadedManifest{ .parsed = parsed, .value = parsed.value };
}

/// Save a `RepoManifest` to disk as pretty-printed JSON.
///
/// @param path Destination manifest file path.
/// @param manifest Manifest struct to serialize.
pub fn save(path: []const u8, manifest: RepoManifest) (std.Io.File.OpenError || std.Io.File.Writer.Error || std.Io.Writer.Error)!void {
    const io = fsutils.defaultIo();
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    var buffer: [1024]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    try std.json.Stringify.value(manifest, .{ .whitespace = .indent_2, .emit_null_optional_fields = true }, &writer.interface);
    try writer.interface.writeAll("\x0a");
    try writer.interface.flush();
}

/// Compare two `RepoManifest` values for exact field-by-field equality.
///
/// @param a First manifest.
/// @param b Second manifest.
/// @return `true` if all fields match.
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

/// Compare two optional string slices for equality.
///
/// @param a First optional string.
/// @param b Second optional string.
/// @return `true` if both are `null` or both contain equal strings.
fn optionalEq(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// Compare two optional `RefKind` values for equality.
///
/// @param a First optional `RefKind`.
/// @param b Second optional `RefKind`.
/// @return `true` if both are `null` or both have the same enum tag.
fn optionalEqRefKind(a: ?types.RefKind, b: ?types.RefKind) bool {
    return a == b;
}

/// Return the manifest directory path (`<cache_dir>/manifest`) for a cache root.
///
/// @param allocator Allocator for the joined path.
/// @param cache_dir Cache root directory path.
/// @return Joined manifest directory path owned by caller.
pub fn manifestDir(allocator: types.Allocator, cache_dir: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.Io.Dir.path.join(allocator, &.{ cache_dir, "manifest" });
}

/// Return the full manifest file path (`<cache_dir>/manifest/<key>.json`) for a cache key.
///
/// @param allocator Allocator for the joined path.
/// @param cache_dir Cache root directory path.
/// @param key Repository cache key.
/// @return Full manifest file path owned by caller.
pub fn manifestPath(allocator: types.Allocator, cache_dir: []const u8, key: []const u8) std.mem.Allocator.Error![]const u8 {
    const dir = try manifestDir(allocator, cache_dir);
    defer allocator.free(dir);
    const filename = try std.mem.concat(allocator, u8, &.{ key, ".json" });
    defer allocator.free(filename);
    return std.Io.Dir.path.join(allocator, &.{ dir, filename });
}

test "manifest equality compares all fields and optional helpers" {
    // covers: manifest.equals manifest.optionalEq manifest.optionalEqRefKind
    const base = RepoManifest{
        .source = "repo",
        .output_subpath = "repo",
        .doc_tool = .mkdocs,
        .doc_path = "docs",
        .ref_kind = .tag,
        .ref_value = "v1.0.0",
        .commit_short = "abc1234",
        .build_hash = 10,
    };

    try std.testing.expect(equals(base, base));

    var diff_doc = base;
    diff_doc.doc_path = null;
    try std.testing.expect(!equals(base, diff_doc));
    try std.testing.expect(equals(diff_doc, diff_doc));

    var diff_kind = base;
    diff_kind.ref_kind = .commit;
    try std.testing.expect(!equals(base, diff_kind));

    var diff_hash = base;
    diff_hash.build_hash = 99;
    try std.testing.expect(!equals(base, diff_hash));
}

test "manifest save, load roundtrip, and missing file return null" {
    // covers: manifest.save manifest.load manifest.deinit manifest.manifestDir manifest.manifestPath
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const cache_dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "cache" });
    defer std.testing.allocator.free(cache_dir);
    try tmp.dir.createDirPath(std.testing.io, "cache");

    const dir_path = try manifestDir(std.testing.allocator, cache_dir);
    defer std.testing.allocator.free(dir_path);
    const file_path = try manifestPath(std.testing.allocator, cache_dir, "repo");
    defer std.testing.allocator.free(file_path);

    try std.testing.expect((try load(std.testing.allocator, file_path)) == null);

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
    try std.testing.expect(equals(manifest, loaded.value));
}
