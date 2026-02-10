const std = @import("std");
const types = @import("types.zig");
const runner = @import("runner.zig");
const fsutils = @import("fsutils.zig");
const builtin = @import("builtin");

/// Archive kinds supported for downloads.
pub const ArchiveKind = enum {
    /// Zip archive.
    zip,
    /// Tar archive.
    tar,
    /// Gzip-compressed tar archive.
    tar_gz,
};

/// Detect the archive kind from a URL or filename.
pub fn detectKind(input: []const u8) ?ArchiveKind {
    const trimmed = trimQuery(input);
    if (std.mem.endsWith(u8, trimmed, ".zip")) return .zip;
    if (std.mem.endsWith(u8, trimmed, ".tar")) return .tar;
    if (std.mem.endsWith(u8, trimmed, ".tar.gz") or std.mem.endsWith(u8, trimmed, ".tgz")) return .tar_gz;
    return null;
}

/// Download an archive to the destination path.
pub fn download(allocator: types.Allocator, url: []const u8, dest_path: []const u8, options: runner.RunOptions) !void {
    if (@import("builtin").os.tag == .windows) {
        const escaped_url = try escapePowerShellLiteral(allocator, url);
        defer allocator.free(escaped_url);
        const escaped_dest = try escapePowerShellLiteral(allocator, dest_path);
        defer allocator.free(escaped_dest);
        const command = if (options.insecure)
            try std.fmt.allocPrint(
                allocator,
                "Invoke-WebRequest -Uri '{s}' -OutFile '{s}' -SkipCertificateCheck",
                .{ escaped_url, escaped_dest },
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "Invoke-WebRequest -Uri '{s}' -OutFile '{s}'",
                .{ escaped_url, escaped_dest },
            );
        defer allocator.free(command);

        var result = try runner.runChecked(
            allocator,
            &.{ "powershell", "-NoProfile", "-Command", command },
            null,
            options,
        );
        result.deinit();
        return;
    }

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "curl");
    try argv.append(allocator, "-L");
    if (options.insecure) {
        try argv.append(allocator, "-k");
    }
    try argv.append(allocator, "-o");
    try argv.append(allocator, dest_path);
    try argv.append(allocator, url);
    var result = try runner.runChecked(allocator, argv.items, null, options);
    result.deinit();
}

/// Extract an archive into a destination directory.
pub fn extract(allocator: types.Allocator, archive_path: []const u8, dest_dir: []const u8, kind: ArchiveKind, options: runner.RunOptions) !void {
    try fsutils.ensureEmptyDir(dest_dir);

    switch (kind) {
        .zip => {
            if (@import("builtin").os.tag == .windows) {
                const escaped_path = try escapePowerShellLiteral(allocator, archive_path);
                defer allocator.free(escaped_path);
                const escaped_dest = try escapePowerShellLiteral(allocator, dest_dir);
                defer allocator.free(escaped_dest);
                const command = try std.fmt.allocPrint(
                    allocator,
                    "Expand-Archive -LiteralPath '{s}' -DestinationPath '{s}'",
                    .{ escaped_path, escaped_dest },
                );
                defer allocator.free(command);
                var result = try runner.runChecked(
                    allocator,
                    &.{ "powershell", "-NoProfile", "-Command", command },
                    null,
                    options,
                );
                result.deinit();
            } else {
                var result = try runner.runChecked(allocator, &.{ "unzip", "-q", archive_path, "-d", dest_dir }, null, options);
                result.deinit();
            }
        },
        .tar_gz => {
            var result = try runner.runChecked(allocator, &.{ "tar", "-xzf", archive_path, "-C", dest_dir }, null, options);
            result.deinit();
        },
        .tar => {
            var result = try runner.runChecked(allocator, &.{ "tar", "-xf", archive_path, "-C", dest_dir }, null, options);
            result.deinit();
        },
    }
}

/// Resolve the top-level directory after extraction.
pub fn resolveRoot(allocator: types.Allocator, dest_dir: []const u8) ![]const u8 {
    var dir = try std.fs.cwd().openDir(dest_dir, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    var first: ?[]const u8 = null;
    var count: usize = 0;

    while (try it.next()) |entry| {
        if (entry.kind == .directory) {
            count += 1;
            if (count == 1) {
                first = try allocator.dupe(u8, entry.name);
            } else {
                break;
            }
        }
    }

    if (count == 1 and first != null) {
        defer allocator.free(first.?);
        return std.fs.path.join(allocator, &.{ dest_dir, first.? });
    }

    if (first) |name| {
        allocator.free(name);
    }

    return allocator.dupe(u8, dest_dir);
}

fn escapePowerShellLiteral(allocator: types.Allocator, input: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    for (input) |ch| {
        if (ch == '\'') {
            try out.appendSlice(allocator, "''");
        } else {
            try out.append(allocator, ch);
        }
    }

    return out.toOwnedSlice(allocator);
}

fn trimQuery(input: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, input, '?')) |idx| {
        return input[0..idx];
    }
    if (std.mem.indexOfScalar(u8, input, '#')) |idx| {
        return input[0..idx];
    }
    return input;
}

/// Remove cached archive downloads not referenced by the provided keys.
pub fn pruneCache(allocator: types.Allocator, cache_dir: []const u8, keep_keys: []const []const u8) !void {
    var dir = std.fs.cwd().openDir(cache_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!isArchiveFile(entry.name)) continue;
        const base = archiveBase(entry.name) orelse continue;
        if (containsKey(keep_keys, base)) continue;

        const path = try std.fs.path.join(allocator, &.{ cache_dir, entry.name });
        defer allocator.free(path);
        try std.fs.cwd().deleteFile(path);
    }
}

fn isArchiveFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".zip") or
        std.mem.endsWith(u8, name, ".tar") or
        std.mem.endsWith(u8, name, ".tar.gz") or
        std.mem.endsWith(u8, name, ".tgz");
}

fn archiveBase(name: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, name, ".tar.gz")) return name[0 .. name.len - ".tar.gz".len];
    if (std.mem.endsWith(u8, name, ".tgz")) return name[0 .. name.len - ".tgz".len];
    if (std.mem.endsWith(u8, name, ".zip")) return name[0 .. name.len - ".zip".len];
    if (std.mem.endsWith(u8, name, ".tar")) return name[0 .. name.len - ".tar".len];
    return null;
}

fn containsKey(keys: []const []const u8, key: []const u8) bool {
    for (keys) |item| {
        if (std.mem.eql(u8, item, key)) return true;
    }
    return false;
}


test "detectKind handles extensions" {
    // covers: archive.detectKind
    try std.testing.expectEqual(@as(?ArchiveKind, .zip), detectKind("https://x/test.zip"));
    try std.testing.expectEqual(@as(?ArchiveKind, .tar_gz), detectKind("https://x/test.tar.gz"));
    try std.testing.expectEqual(@as(?ArchiveKind, null), detectKind("https://x/test"));
}

test "resolveRoot picks single directory" {
    // covers: archive.resolveRoot
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("rootdir/sub");
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    const resolved = try resolveRoot(std.testing.allocator, path);
    defer std.testing.allocator.free(resolved);

    try std.testing.expect(std.mem.endsWith(u8, resolved, "rootdir") or std.mem.endsWith(u8, resolved, "rootdir\\"));
}

test "download uses curl on non-windows" {
    // covers: archive.download
    if (builtin.os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const dest = try std.fs.path.join(std.testing.allocator, &.{ base, "file.zip" });
    defer std.testing.allocator.free(dest);

    const fake = runner.TestRunner{ .run = struct {
        fn run(alloc: types.Allocator, argv: []const []const u8, _: ?[]const u8, _: runner.RunOptions) anyerror!runner.RunResult {
            test_last_len = argv.len;
            for (argv, 0..) |arg, idx| {
                if (idx < test_last_argv.len) test_last_argv[idx] = arg;
            }
            const out = try alloc.alloc(u8, 0);
            return runner.RunResult{ .stdout = out, .stderr = out, .term = .{ .Exited = 0 }, .allocator = alloc };
        }
    }.run };

    test_last_len = 0;
    runner.setTestRunner(fake);
    defer runner.setTestRunner(null);

    try download(std.testing.allocator, "https://example.com/repo.zip", dest, .{});
    try std.testing.expectEqualStrings("curl", test_last_argv[0]);
    try std.testing.expect(test_last_len > 0);
}

test "extract uses unzip on non-windows" {
    // covers: archive.extract
    if (builtin.os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const dest_dir = try std.fs.path.join(std.testing.allocator, &.{ base, "out" });
    defer std.testing.allocator.free(dest_dir);

    const fake = runner.TestRunner{ .run = struct {
        fn run(alloc: types.Allocator, argv: []const []const u8, _: ?[]const u8, _: runner.RunOptions) anyerror!runner.RunResult {
            test_last_len = argv.len;
            for (argv, 0..) |arg, idx| {
                if (idx < test_last_argv.len) test_last_argv[idx] = arg;
            }
            const out = try alloc.alloc(u8, 0);
            return runner.RunResult{ .stdout = out, .stderr = out, .term = .{ .Exited = 0 }, .allocator = alloc };
        }
    }.run };

    test_last_len = 0;
    runner.setTestRunner(fake);
    defer runner.setTestRunner(null);

    try extract(std.testing.allocator, "repo.zip", dest_dir, .zip, .{});
    try std.testing.expectEqualStrings("unzip", test_last_argv[0]);
    try std.testing.expect(test_last_len > 0);
}

test "pruneCache removes unused archives" {
    // covers: archive.pruneCache
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "keep.zip", .data = "ok" });
    try tmp.dir.writeFile(.{ .sub_path = "drop.tar.gz", .data = "ok" });
    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);

    try pruneCache(std.testing.allocator, base, &.{ "keep" });

    const keep_path = try std.fs.path.join(std.testing.allocator, &.{ base, "keep.zip" });
    defer std.testing.allocator.free(keep_path);
    const drop_path = try std.fs.path.join(std.testing.allocator, &.{ base, "drop.tar.gz" });
    defer std.testing.allocator.free(drop_path);
    try std.testing.expect(fsutils.fileExists(keep_path));
    try std.testing.expect(!fsutils.fileExists(drop_path));
}

var test_last_argv: [8][]const u8 = undefined;
var test_last_len: usize = 0;
