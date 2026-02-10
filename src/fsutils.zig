const std = @import("std");
const types = @import("types.zig");

/// Ensure a directory exists, creating parents as needed.
pub fn ensureDir(path: []const u8) !void {
    try std.fs.cwd().makePath(path);
}

/// Ensure a directory exists and is empty.
pub fn ensureEmptyDir(path: []const u8) !void {
    if (dirExists(path)) {
        try std.fs.cwd().deleteTree(path);
    }
    try std.fs.cwd().makePath(path);
}

/// Check whether a directory exists.
pub fn dirExists(path: []const u8) bool {
    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    dir.close();
    return true;
}

/// Check whether a file exists.
pub fn fileExists(path: []const u8) bool {
    var file = std.fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}

/// Copy a directory tree recursively.
pub fn copyDir(allocator: types.Allocator, src_path: []const u8, dest_path: []const u8) !void {
    try ensureDir(dest_path);
    var src = try std.fs.cwd().openDir(src_path, .{ .iterate = true });
    defer src.close();

    var it = src.iterate();
    while (try it.next()) |entry| {
        const src_item = try std.fs.path.join(allocator, &.{ src_path, entry.name });
        defer allocator.free(src_item);
        const dest_item = try std.fs.path.join(allocator, &.{ dest_path, entry.name });
        defer allocator.free(dest_item);

        switch (entry.kind) {
            .directory => try copyDir(allocator, src_item, dest_item),
            .file => {
                try ensureDir(dest_path);
                try std.fs.cwd().copyFile(src_item, std.fs.cwd(), dest_item, .{});
            },
            else => {},
        }
    }
}

/// Return a filesystem-safe name derived from input.
pub fn sanitizeName(allocator: types.Allocator, input: []const u8) ![]const u8 {
    var buffer = try allocator.alloc(u8, input.len);
    var i: usize = 0;
    for (input) |ch| {
        buffer[i] = switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => ch,
            else => '-',
        };
        i += 1;
    }
    return buffer[0..i];
}

/// Write a small file, overwriting if it exists.
pub fn writeFile(path: []const u8, contents: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(contents);
}

/// Glob filter for include/exclude file selection.
pub const GlobFilter = struct {
    /// Optional include glob to allow files.
    include: ?[]const u8 = null,
    /// Optional exclude glob to skip files and directories.
    exclude: ?[]const u8 = null,
};

/// Copy a directory tree while applying include/exclude globs.
pub fn copyDirFiltered(allocator: types.Allocator, src_path: []const u8, dest_path: []const u8, filter: GlobFilter) !void {
    try copyDirFilteredInner(allocator, src_path, dest_path, filter, "");
}

fn copyDirFilteredInner(
    allocator: types.Allocator,
    src_path: []const u8,
    dest_path: []const u8,
    filter: GlobFilter,
    rel_prefix: []const u8,
) !void {
    try ensureDir(dest_path);
    var src = try std.fs.cwd().openDir(src_path, .{ .iterate = true });
    defer src.close();

    var it = src.iterate();
    while (try it.next()) |entry| {
        const rel = try joinRel(allocator, rel_prefix, entry.name);
        defer allocator.free(rel);

        if (entry.kind == .directory) {
            if (filter.exclude) |pat| {
                if (matchGlob(pat, rel)) continue;
            }
            const src_item = try std.fs.path.join(allocator, &.{ src_path, entry.name });
            defer allocator.free(src_item);
            const dest_item = try std.fs.path.join(allocator, &.{ dest_path, entry.name });
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

        const src_item = try std.fs.path.join(allocator, &.{ src_path, entry.name });
        defer allocator.free(src_item);
        const dest_item = try std.fs.path.join(allocator, &.{ dest_path, entry.name });
        defer allocator.free(dest_item);
        try ensureDir(dest_path);
        try std.fs.cwd().copyFile(src_item, std.fs.cwd(), dest_item, .{});
    }
}

fn joinRel(allocator: types.Allocator, prefix: []const u8, name: []const u8) ![]const u8 {
    if (prefix.len == 0) return allocator.dupe(u8, name);
    return std.mem.concat(allocator, u8, &.{ prefix, "/", name });
}

/// Simple glob matcher supporting '*' and '?' wildcards.
pub fn matchGlob(pattern: []const u8, text: []const u8) bool {
    return matchGlobInner(pattern, text, 0, 0);
}

fn matchGlobInner(pattern: []const u8, text: []const u8, p_index: usize, t_index: usize) bool {
    var p = p_index;
    var t = t_index;
    while (p < pattern.len) {
        const ch = pattern[p];
        if (ch == '*') {
            while (p < pattern.len and pattern[p] == '*') p += 1;
            if (p == pattern.len) return true;
            while (t <= text.len) : (t += 1) {
                if (matchGlobInner(pattern, text, p, t)) return true;
            }
            return false;
        }
        if (t >= text.len) return false;
        if (ch != '?' and ch != text[t]) return false;
        p += 1;
        t += 1;
    }
    return t == text.len;
}

test "sanitize name replaces unsafe characters" {
    // covers: fsutils.sanitizeName
    const allocator = std.testing.allocator;
    const out = try sanitizeName(allocator, "hello world!");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("hello-world-", out);
}

test "ensureDir creates missing directories" {
    // covers: fsutils.ensureDir fsutils.dirExists
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const nested = try std.fs.path.join(std.testing.allocator, &.{ base, "a", "b" });
    defer std.testing.allocator.free(nested);

    try ensureDir(nested);
    try std.testing.expect(dirExists(nested));
}

test "ensureEmptyDir clears contents" {
    // covers: fsutils.ensureEmptyDir
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("nested");
    try tmp.dir.writeFile(.{ .sub_path = "nested/file.txt", .data = "data" });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    try ensureEmptyDir(path);

    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    try std.testing.expectEqual(@as(?std.fs.Dir.Entry, null), try it.next());
}

test "matchGlob handles wildcards" {
    // covers: fsutils.matchGlob
    try std.testing.expect(matchGlob("docs/*.md", "docs/readme.md"));
    try std.testing.expect(matchGlob("docs/**", "docs/sub/guide.md"));
    try std.testing.expect(!matchGlob("docs/*.md", "docs/readme.txt"));
}

test "copyDir copies files recursively" {
    // covers: fsutils.copyDir fsutils.fileExists
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src/nested");
    try tmp.dir.writeFile(.{ .sub_path = "src/nested/file.txt", .data = "ok" });

    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const src = try std.fs.path.join(std.testing.allocator, &.{ base, "src" });
    defer std.testing.allocator.free(src);
    const dest = try std.fs.path.join(std.testing.allocator, &.{ base, "dest" });
    defer std.testing.allocator.free(dest);

    try copyDir(std.testing.allocator, src, dest);

    const copied = try std.fs.path.join(std.testing.allocator, &.{ dest, "nested", "file.txt" });
    defer std.testing.allocator.free(copied);
    try std.testing.expect(fileExists(copied));
}

test "copyDirFiltered applies include and exclude" {
    // covers: fsutils.copyDirFiltered
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src/docs");
    try tmp.dir.makePath("src/build");
    try tmp.dir.writeFile(.{ .sub_path = "src/docs/readme.md", .data = "ok" });
    try tmp.dir.writeFile(.{ .sub_path = "src/docs/skip.txt", .data = "no" });
    try tmp.dir.writeFile(.{ .sub_path = "src/build/output.md", .data = "no" });

    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const src = try std.fs.path.join(std.testing.allocator, &.{ base, "src" });
    defer std.testing.allocator.free(src);
    const dest = try std.fs.path.join(std.testing.allocator, &.{ base, "dest" });
    defer std.testing.allocator.free(dest);

    try copyDirFiltered(std.testing.allocator, src, dest, .{ .include = "docs/*.md", .exclude = "build/**" });

    const kept = try std.fs.path.join(std.testing.allocator, &.{ dest, "docs", "readme.md" });
    defer std.testing.allocator.free(kept);
    try std.testing.expect(fileExists(kept));
    const skipped = try std.fs.path.join(std.testing.allocator, &.{ dest, "docs", "skip.txt" });
    defer std.testing.allocator.free(skipped);
    try std.testing.expect(!fileExists(skipped));
    const excluded = try std.fs.path.join(std.testing.allocator, &.{ dest, "build", "output.md" });
    defer std.testing.allocator.free(excluded);
    try std.testing.expect(!fileExists(excluded));
}

test "writeFile writes contents to disk" {
    // covers: fsutils.writeFile
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const path = try std.fs.path.join(std.testing.allocator, &.{ base, "note.txt" });
    defer std.testing.allocator.free(path);

    try writeFile(path, "hello");
    const data = try tmp.dir.readFileAlloc(std.testing.allocator, "note.txt", 1024);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("hello", data);
}
