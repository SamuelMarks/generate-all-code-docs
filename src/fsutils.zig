//! Filesystem operations, recursive directory copying, name sanitization, and glob matching.

const std = @import("std");
const types = @import("types.zig");

/// Return the default `std.Io` instance for filesystem operations.
///
/// @return Active `std.Io` interface.
pub fn defaultIo() std.Io {
    return std.Options.debug_io;
}

/// Ensure a directory exists, creating parent directories as needed.
///
/// @param path Target directory path.
pub fn ensureDir(path: []const u8) std.Io.Dir.CreateDirPathError!void {
    try std.Io.Dir.cwd().createDirPath(defaultIo(), path);
}

/// Ensure a directory exists and is completely empty.
///
/// @param path Target directory path to wipe and recreate.
pub fn ensureEmptyDir(path: []const u8) (std.Io.Dir.DeleteTreeError || std.Io.Dir.CreateDirPathError)!void {
    const io = defaultIo();
    if (dirExists(path)) {
        try std.Io.Dir.cwd().deleteTree(io, path);
    }
    try std.Io.Dir.cwd().createDirPath(io, path);
}

/// Check whether a directory exists at `path`.
///
/// @param path Directory path to inspect.
/// @return `true` if `path` can be opened as a directory.
pub fn dirExists(path: []const u8) bool {
    const io = defaultIo();
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

/// Check whether a file exists at `path`.
///
/// @param path File path to inspect.
/// @return `true` if `path` can be opened as a file.
pub fn fileExists(path: []const u8) bool {
    const io = defaultIo();
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

/// Copy a directory tree recursively from `src_path` to `dest_path`.
///
/// @param allocator Allocator for temporary path joins.
/// @param src_path Source directory path.
/// @param dest_path Destination directory path.
pub fn copyDir(allocator: types.Allocator, src_path: []const u8, dest_path: []const u8) types.GenerateAllCodeDocsError!void {
    const io = defaultIo();
    try ensureDir(dest_path);
    var src = try std.Io.Dir.cwd().openDir(io, src_path, .{ .iterate = true });
    defer src.close(io);

    var it = src.iterate();
    while (try it.next(io)) |entry| {
        const src_item = try std.Io.Dir.path.join(allocator, &.{ src_path, entry.name });
        defer allocator.free(src_item);
        const dest_item = try std.Io.Dir.path.join(allocator, &.{ dest_path, entry.name });
        defer allocator.free(dest_item);

        switch (entry.kind) {
            .directory => try copyDir(allocator, src_item, dest_item),
            .file => {
                try ensureDir(dest_path);
                try std.Io.Dir.cwd().copyFile(src_item, std.Io.Dir.cwd(), dest_item, io, .{});
            },
            else => {},
        }
    }
}

/// Return a filesystem-safe name derived from `input` by replacing non-alphanumeric characters with `-`.
///
/// @param allocator Allocator for the output slice.
/// @param input Raw name string.
/// @return Allocated, sanitized string slice owned by caller.
pub fn sanitizeName(allocator: types.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8 {
    var buffer = try allocator.alloc(u8, input.len);
    for (input, 0..) |ch, i| {
        buffer[i] = switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => ch,
            else => '-',
        };
    }
    return buffer;
}

/// Write `contents` to `path`, truncating or creating the file.
///
/// @param path Destination file path.
/// @param contents Bytes to write.
pub fn writeFile(path: []const u8, contents: []const u8) (std.Io.File.OpenError || std.Io.File.Writer.Error)!void {
    const io = defaultIo();
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

/// Glob filter for include/exclude file selection during filtered directory copies.
pub const GlobFilter = struct {
    /// Optional include glob to allow files.
    include: ?[]const u8 = null,
    /// Optional exclude glob to skip files and directories.
    exclude: ?[]const u8 = null,
};

/// Copy a directory tree while applying include/exclude globs to relative paths.
///
/// @param allocator Allocator for path buffers.
/// @param src_path Source directory root.
/// @param dest_path Destination directory root.
/// @param filter Include/exclude glob patterns.
pub fn copyDirFiltered(
    allocator: types.Allocator,
    src_path: []const u8,
    dest_path: []const u8,
    filter: GlobFilter,
) types.GenerateAllCodeDocsError!void {
    try copyDirFilteredInner(allocator, src_path, dest_path, filter, "");
}

/// Recursive helper for `copyDirFiltered` tracking the slash-separated relative prefix.
///
/// @param allocator Allocator for temporary paths.
/// @param src_path Current source directory path.
/// @param dest_path Current destination directory path.
/// @param filter Active `GlobFilter`.
/// @param rel_prefix Relative path from the root directory.
fn copyDirFilteredInner(
    allocator: types.Allocator,
    src_path: []const u8,
    dest_path: []const u8,
    filter: GlobFilter,
    rel_prefix: []const u8,
) types.GenerateAllCodeDocsError!void {
    const io = defaultIo();
    try ensureDir(dest_path);
    var src = try std.Io.Dir.cwd().openDir(io, src_path, .{ .iterate = true });
    defer src.close(io);

    var it = src.iterate();
    while (try it.next(io)) |entry| {
        const rel = try joinRel(allocator, rel_prefix, entry.name);
        defer allocator.free(rel);

        if (entry.kind == .directory) {
            if (filter.exclude) |pat| {
                if (matchGlob(pat, rel)) continue;
            }
            const src_item = try std.Io.Dir.path.join(allocator, &.{ src_path, entry.name });
            defer allocator.free(src_item);
            const dest_item = try std.Io.Dir.path.join(allocator, &.{ dest_path, entry.name });
            defer allocator.free(dest_item);
            try copyDirFilteredInner(allocator, src_item, dest_item, filter, rel);
            continue;
        }

        if (entry.kind != .file) continue;

        if (filter.include) |pat| {
            if (!matchGlob(pat, rel)) continue;
        }
        if (filter.exclude) |pat| {
            if (matchGlob(pat, rel)) continue;
        }

        const src_item = try std.Io.Dir.path.join(allocator, &.{ src_path, entry.name });
        defer allocator.free(src_item);
        const dest_item = try std.Io.Dir.path.join(allocator, &.{ dest_path, entry.name });
        defer allocator.free(dest_item);
        try ensureDir(dest_path);
        try std.Io.Dir.cwd().copyFile(src_item, std.Io.Dir.cwd(), dest_item, io, .{});
    }
}

/// Join a relative path prefix and entry name with `/`.
///
/// @param allocator Allocator for the joined string.
/// @param prefix Relative prefix (empty at root).
/// @param name Entry filename or directory name.
/// @return Joined relative path owned by caller.
fn joinRel(allocator: types.Allocator, prefix: []const u8, name: []const u8) std.mem.Allocator.Error![]const u8 {
    if (prefix.len == 0) return allocator.dupe(u8, name);
    return std.mem.concat(allocator, u8, &.{ prefix, "/", name });
}

/// Iterative linear/quadratic-bounded glob matcher supporting `*` and `?` wildcards without recursion or exponential backtracking.
///
/// @param pattern Glob pattern containing literals, `?`, or `*`.
/// @param text Candidate string to match against `pattern`.
/// @return `true` if `text` matches `pattern` completely.
pub fn matchGlob(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (t < text.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == text[t])) {
            p += 1;
            t += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            while (p < pattern.len and pattern[p] == '*') {
                p += 1;
            }
            if (p == pattern.len) return true;
            star_idx = p;
            match_idx = t;
        } else if (star_idx) |s_pos| {
            p = s_pos;
            match_idx += 1;
            t = match_idx;
        } else {
            return false;
        }
    }

    while (p < pattern.len and pattern[p] == '*') {
        p += 1;
    }

    return p == pattern.len;
}

test "sanitizeName replaces unsafe characters" {
    // covers: fsutils.sanitizeName
    const allocator = std.testing.allocator;
    const out = try sanitizeName(allocator, "hello world!_1.0-rc");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("hello-world-_1.0-rc", out);
}

test "ensureDir and dirExists and fileExists handle present and missing paths" {
    // covers: fsutils.defaultIo fsutils.ensureDir fsutils.dirExists fsutils.fileExists
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const nested = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "a", "b" });
    defer std.testing.allocator.free(nested);
    const missing = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "does_not_exist" });
    defer std.testing.allocator.free(missing);

    try std.testing.expect(!dirExists(missing));
    try std.testing.expect(!fileExists(missing));

    try ensureDir(nested);
    try std.testing.expect(dirExists(nested));
}

test "ensureEmptyDir clears existing directory and creates missing directory" {
    // covers: fsutils.ensureEmptyDir
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "nested");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "nested/file.txt", .data = "data" });

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const existing = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "nested" });
    defer std.testing.allocator.free(existing);
    const fresh = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "fresh" });
    defer std.testing.allocator.free(fresh);

    try ensureEmptyDir(existing);
    try ensureEmptyDir(fresh);
    try std.testing.expect(dirExists(fresh));

    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, existing, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    try std.testing.expectEqual(@as(?std.Io.Dir.Entry, null), try it.next(std.testing.io));
}

test "matchGlob handles wildcards, question marks, backtracking, and mismatches" {
    // covers: fsutils.matchGlob
    try std.testing.expect(matchGlob("docs/*.md", "docs/readme.md"));
    try std.testing.expect(matchGlob("docs/**", "docs/sub/guide.md"));
    try std.testing.expect(matchGlob("a?c*e*", "abcdef"));
    try std.testing.expect(matchGlob("*a*b*c*", "xxayybzzc"));
    try std.testing.expect(matchGlob("trailing*", "trailing"));
    try std.testing.expect(!matchGlob("docs/*.md", "docs/readme.txt"));
    try std.testing.expect(!matchGlob("docs/*.md", "other/readme.md"));
    try std.testing.expect(!matchGlob("abc", "ab"));
    try std.testing.expect(!matchGlob("*z", "abc"));
}

test "copyDir copies files recursively" {
    // covers: fsutils.copyDir
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src/nested");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/nested/file.txt", .data = "ok" });

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const src = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "src" });
    defer std.testing.allocator.free(src);
    const dest = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "dest" });
    defer std.testing.allocator.free(dest);

    try copyDir(std.testing.allocator, src, dest);

    const copied = try std.Io.Dir.path.join(std.testing.allocator, &.{ dest, "nested", "file.txt" });
    defer std.testing.allocator.free(copied);
    try std.testing.expect(fileExists(copied));
}

test "copyDirFiltered applies include and exclude on files and directories" {
    // covers: fsutils.copyDirFiltered fsutils.copyDirFilteredInner fsutils.joinRel
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src/docs");
    try tmp.dir.createDirPath(std.testing.io, "src/build");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/docs/readme.md", .data = "ok" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/docs/excluded.md", .data = "no" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/docs/skip.txt", .data = "no" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/build/output.md", .data = "no" });

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const src = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "src" });
    defer std.testing.allocator.free(src);
    const dest = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "dest" });
    defer std.testing.allocator.free(dest);

    try copyDirFiltered(std.testing.allocator, src, dest, .{ .include = "docs/*.md", .exclude = "*excluded*" });

    const kept = try std.Io.Dir.path.join(std.testing.allocator, &.{ dest, "docs", "readme.md" });
    defer std.testing.allocator.free(kept);
    try std.testing.expect(fileExists(kept));

    const file_excluded = try std.Io.Dir.path.join(std.testing.allocator, &.{ dest, "docs", "excluded.md" });
    defer std.testing.allocator.free(file_excluded);
    try std.testing.expect(!fileExists(file_excluded));

    const skipped = try std.Io.Dir.path.join(std.testing.allocator, &.{ dest, "docs", "skip.txt" });
    defer std.testing.allocator.free(skipped);
    try std.testing.expect(!fileExists(skipped));

    const dest2 = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "dest2" });
    defer std.testing.allocator.free(dest2);
    try copyDirFiltered(std.testing.allocator, src, dest2, .{ .include = null, .exclude = "build" });
    const dir_excluded = try std.Io.Dir.path.join(std.testing.allocator, &.{ dest2, "build", "output.md" });
    defer std.testing.allocator.free(dir_excluded);
    try std.testing.expect(!fileExists(dir_excluded));
}

test "writeFile writes contents to disk" {
    // covers: fsutils.writeFile
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const path = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "note.txt" });
    defer std.testing.allocator.free(path);

    try writeFile(path, "hello");
    const data = try tmp.dir.readFileAlloc(std.testing.io, "note.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("hello", data);
}
