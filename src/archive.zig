//! Archive kind detection, downloading, extraction, root directory unwrapping, and cache pruning.

const std = @import("std");
const types = @import("types.zig");
const runner = @import("runner.zig");
const fsutils = @import("fsutils.zig");
const paths = @import("paths.zig");
const builtin = @import("builtin");

/// Alias of `types.ArchiveKind` for module callers.
pub const ArchiveKind = types.ArchiveKind;

/// Detect the archive kind from a URL or file path.
///
/// @param url Archive URL or filename.
/// @return Detected `ArchiveKind`, or `null` if not supported.
pub fn detectKind(url: []const u8) ?ArchiveKind {
    return paths.detectArchiveKind(url);
}

/// Build the platform-specific download command (`curl` on POSIX, `powershell` on Windows).
///
/// @param allocator Allocator for constructing the argument list and script string.
/// @param url Source URL to download.
/// @param dest_path Destination file path on disk.
/// @param insecure Whether to skip TLS certificate verification.
/// @param is_windows True when building a Windows PowerShell command.
/// @return Owned slice of owned argument strings (`freeCommandArgv` to release).
pub fn buildDownloadCommand(
    allocator: types.Allocator,
    url: []const u8,
    dest_path: []const u8,
    insecure: bool,
    is_windows: bool,
) std.mem.Allocator.Error![][]const u8 {
    var argv = std.ArrayList([]const u8).empty;
    errdefer freeCommandList(allocator, &argv);

    if (is_windows) {
        const escaped_url = try escapePowerShellLiteral(allocator, url);
        defer allocator.free(escaped_url);
        const escaped_dest = try escapePowerShellLiteral(allocator, dest_path);
        defer allocator.free(escaped_dest);
        const prefix = if (insecure)
            "[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}; "
        else
            "";
        const cmd = try std.fmt.allocPrint(
            allocator,
            "{s}Invoke-WebRequest -Uri '{s}' -OutFile '{s}'",
            .{ prefix, escaped_url, escaped_dest },
        );
        errdefer allocator.free(cmd);
        try argv.append(allocator, try allocator.dupe(u8, "powershell"));
        try argv.append(allocator, try allocator.dupe(u8, "-NoProfile"));
        try argv.append(allocator, try allocator.dupe(u8, "-Command"));
        try argv.append(allocator, cmd);
        return argv.toOwnedSlice(allocator);
    }

    try argv.append(allocator, try allocator.dupe(u8, "curl"));
    try argv.append(allocator, try allocator.dupe(u8, "-L"));
    if (insecure) {
        try argv.append(allocator, try allocator.dupe(u8, "-k"));
    }
    try argv.append(allocator, try allocator.dupe(u8, "-o"));
    try argv.append(allocator, try allocator.dupe(u8, dest_path));
    try argv.append(allocator, try allocator.dupe(u8, url));
    return argv.toOwnedSlice(allocator);
}

/// Build the platform-specific archive extraction command (`unzip`/`tar` on POSIX, `powershell`/`tar` on Windows).
///
/// @param allocator Allocator for constructing the argument list.
/// @param archive_path Path to the archive file on disk.
/// @param dest_dir Target directory for extracted contents.
/// @param kind Archive format (`zip`, `tar`, or `tar_gz`).
/// @param is_windows True when building a Windows extraction command for `.zip`.
/// @return Owned slice of owned argument strings (`freeCommandArgv` to release).
pub fn buildExtractCommand(
    allocator: types.Allocator,
    archive_path: []const u8,
    dest_dir: []const u8,
    kind: ArchiveKind,
    is_windows: bool,
) std.mem.Allocator.Error![][]const u8 {
    var argv = std.ArrayList([]const u8).empty;
    errdefer freeCommandList(allocator, &argv);

    switch (kind) {
        .zip => {
            if (is_windows) {
                const escaped_archive = try escapePowerShellLiteral(allocator, archive_path);
                defer allocator.free(escaped_archive);
                const escaped_dest = try escapePowerShellLiteral(allocator, dest_dir);
                defer allocator.free(escaped_dest);
                const cmd = try std.fmt.allocPrint(
                    allocator,
                    "Expand-Archive -Path '{s}' -DestinationPath '{s}' -Force",
                    .{ escaped_archive, escaped_dest },
                );
                errdefer allocator.free(cmd);
                try argv.append(allocator, try allocator.dupe(u8, "powershell"));
                try argv.append(allocator, try allocator.dupe(u8, "-NoProfile"));
                try argv.append(allocator, try allocator.dupe(u8, "-Command"));
                try argv.append(allocator, cmd);
            } else {
                try argv.append(allocator, try allocator.dupe(u8, "unzip"));
                try argv.append(allocator, try allocator.dupe(u8, "-q"));
                try argv.append(allocator, try allocator.dupe(u8, archive_path));
                try argv.append(allocator, try allocator.dupe(u8, "-d"));
                try argv.append(allocator, try allocator.dupe(u8, dest_dir));
            }
        },
        .tar => {
            try argv.append(allocator, try allocator.dupe(u8, "tar"));
            try argv.append(allocator, try allocator.dupe(u8, "-xf"));
            try argv.append(allocator, try allocator.dupe(u8, archive_path));
            try argv.append(allocator, try allocator.dupe(u8, "-C"));
            try argv.append(allocator, try allocator.dupe(u8, dest_dir));
        },
        .tar_gz => {
            try argv.append(allocator, try allocator.dupe(u8, "tar"));
            try argv.append(allocator, try allocator.dupe(u8, "-xzf"));
            try argv.append(allocator, try allocator.dupe(u8, archive_path));
            try argv.append(allocator, try allocator.dupe(u8, "-C"));
            try argv.append(allocator, try allocator.dupe(u8, dest_dir));
        },
    }

    return argv.toOwnedSlice(allocator);
}

/// Free a command argument vector allocated by `buildDownloadCommand` or `buildExtractCommand`.
///
/// @param allocator Allocator that owns the slice and its elements.
/// @param argv Slice of argument strings to free.
pub fn freeCommandArgv(allocator: types.Allocator, argv: [][]const u8) void {
    for (argv) |item| {
        allocator.free(item);
    }
    allocator.free(argv);
}

/// Free elements of an `ArrayList([]const u8)` during `errdefer` cleanup.
///
/// @param allocator Allocator that owns the list and its elements.
/// @param list Pointer to the `ArrayList` being cleaned up.
fn freeCommandList(allocator: types.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |item| {
        allocator.free(item);
    }
    list.deinit(allocator);
}

/// Download an archive to `dest_path` if it does not already exist in the cache.
///
/// @param allocator Allocator for command execution.
/// @param url Source URL of the archive.
/// @param dest_path Destination file path in cache.
/// @param options Runner execution options.
pub fn ensureDownload(
    allocator: types.Allocator,
    url: []const u8,
    dest_path: []const u8,
    options: runner.RunOptions,
) types.GenerateAllCodeDocsError!void {
    if (fsutils.fileExists(dest_path)) {
        return;
    }

    const argv = try buildDownloadCommand(allocator, url, dest_path, options.insecure, builtin.os.tag == .windows);
    defer freeCommandArgv(allocator, argv);
    var result = try runner.runChecked(allocator, argv, null, options);
    result.deinit();
}

/// Extract an archive file into `dest_dir`, wiping `dest_dir` first.
///
/// @param allocator Allocator for command execution.
/// @param archive_path Path to the cached archive file.
/// @param dest_dir Destination extraction directory.
/// @param kind Archive format (`zip`, `tar`, or `tar_gz`).
/// @param options Runner execution options.
pub fn extract(
    allocator: types.Allocator,
    archive_path: []const u8,
    dest_dir: []const u8,
    kind: ArchiveKind,
    options: runner.RunOptions,
) types.GenerateAllCodeDocsError!void {
    try fsutils.ensureEmptyDir(dest_dir);

    const argv = try buildExtractCommand(allocator, archive_path, dest_dir, kind, builtin.os.tag == .windows);
    defer freeCommandArgv(allocator, argv);
    var result = try runner.runChecked(allocator, argv, null, options);
    result.deinit();
}

/// Escape single quotes (`'` -> `''`) for safe inclusion in a single-quoted PowerShell string literal.
///
/// @param allocator Allocator for the escaped string.
/// @param input Raw string to escape.
/// @return Newly allocated escaped string.
fn escapePowerShellLiteral(allocator: types.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    for (input) |ch| {
        if (ch == '\x27') {
            try out.appendSlice(allocator, "''");
        } else {
            try out.append(allocator, ch);
        }
    }

    return out.toOwnedSlice(allocator);
}

/// Resolve the effective repository root inside an extracted directory.
/// Descends into a single child directory ONLY if there is exactly 1 child directory and 0 top-level files.
///
/// @param allocator Allocator for the returned path string.
/// @param extracted_dir Path to the directory where the archive was extracted.
/// @return Resolved root directory path owned by caller.
pub fn resolveRoot(allocator: types.Allocator, extracted_dir: []const u8) types.GenerateAllCodeDocsError![]const u8 {
    const io = fsutils.defaultIo();
    var dir = try std.Io.Dir.cwd().openDir(io, extracted_dir, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    var first_dir: ?[]const u8 = null;
    errdefer if (first_dir) |item| allocator.free(item);
    var dir_count: usize = 0;
    var other_count: usize = 0;

    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            dir_count += 1;
            if (dir_count == 1) {
                first_dir = try allocator.dupe(u8, entry.name);
            }
        } else {
            other_count += 1;
        }
    }

    if (dir_count == 1 and other_count == 0) {
        defer allocator.free(first_dir.?);
        return std.Io.Dir.path.join(allocator, &.{ extracted_dir, first_dir.? });
    }

    if (first_dir) |item| allocator.free(item);
    return allocator.dupe(u8, extracted_dir);
}

/// Remove cached archive files in `cache_dir` whose base cache key is not in `keep_keys`.
///
/// @param allocator Allocator for temporary path joins.
/// @param cache_dir Cache root directory path.
/// @param keep_keys Slice of active archive cache keys to retain.
pub fn pruneCache(
    allocator: types.Allocator,
    cache_dir: []const u8,
    keep_keys: []const []const u8,
) types.GenerateAllCodeDocsError!void {
    const io = fsutils.defaultIo();
    var dir = std.Io.Dir.cwd().openDir(io, cache_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const base = paths.archiveBaseName(entry.name) orelse continue;
        if (paths.containsKey(keep_keys, base)) continue;

        const path = try std.Io.Dir.path.join(allocator, &.{ cache_dir, entry.name });
        defer allocator.free(path);
        try std.Io.Dir.cwd().deleteFile(io, path);
    }
}

test "detectKind handles zip, tar, tar.gz, tgz, and unsupported extensions" {
    // covers: archive.detectKind
    try std.testing.expectEqual(@as(?ArchiveKind, .zip), detectKind("https://example.com/a.zip"));
    try std.testing.expectEqual(@as(?ArchiveKind, .tar_gz), detectKind("https://example.com/a.tar.gz"));
    try std.testing.expectEqual(@as(?ArchiveKind, .tar_gz), detectKind("https://example.com/a.tgz?dl=1"));
    try std.testing.expectEqual(@as(?ArchiveKind, .tar), detectKind("https://example.com/a.tar#frag"));
    try std.testing.expectEqual(@as(?ArchiveKind, null), detectKind("https://example.com/a.rar"));
}

test "buildDownloadCommand and buildExtractCommand cover POSIX and Windows branches" {
    // covers: archive.buildDownloadCommand archive.buildExtractCommand archive.freeCommandArgv archive.freeCommandList archive.escapePowerShellLiteral
    const allocator = std.testing.allocator;

    const posix_dl = try buildDownloadCommand(allocator, "https://example.com/a.zip", "/tmp/a.zip", true, false);
    defer freeCommandArgv(allocator, posix_dl);
    try std.testing.expectEqualStrings("curl", posix_dl[0]);
    try std.testing.expectEqualStrings("-L", posix_dl[1]);
    try std.testing.expectEqualStrings("-k", posix_dl[2]);

    const win_dl = try buildDownloadCommand(allocator, "https://example.com/a'b.zip", "C:\x5ca'b.zip", true, true);
    defer freeCommandArgv(allocator, win_dl);
    try std.testing.expectEqualStrings("powershell", win_dl[0]);
    try std.testing.expect(std.mem.containsAtLeast(u8, win_dl[3], 1, "ServerCertificateValidationCallback"));
    try std.testing.expect(std.mem.containsAtLeast(u8, win_dl[3], 1, "a''b.zip"));

    const win_dl_secure = try buildDownloadCommand(allocator, "https://example.com/a.zip", "C:\x5ca.zip", false, true);
    defer freeCommandArgv(allocator, win_dl_secure);
    try std.testing.expect(!std.mem.containsAtLeast(u8, win_dl_secure[3], 1, "ServerCertificateValidationCallback"));

    const win_zip = try buildExtractCommand(allocator, "C:\x5ca'b.zip", "C:\x5cout", .zip, true);
    defer freeCommandArgv(allocator, win_zip);
    try std.testing.expectEqualStrings("powershell", win_zip[0]);
    try std.testing.expect(std.mem.containsAtLeast(u8, win_zip[3], 1, "Expand-Archive"));

    const posix_zip = try buildExtractCommand(allocator, "/tmp/a.zip", "/tmp/out", .zip, false);
    defer freeCommandArgv(allocator, posix_zip);
    try std.testing.expectEqualStrings("unzip", posix_zip[0]);

    const tar_cmd = try buildExtractCommand(allocator, "/tmp/a.tar", "/tmp/out", .tar, false);
    defer freeCommandArgv(allocator, tar_cmd);
    try std.testing.expectEqualStrings("tar", tar_cmd[0]);
    try std.testing.expectEqualStrings("-xf", tar_cmd[1]);

    const tgz_cmd = try buildExtractCommand(allocator, "/tmp/a.tar.gz", "/tmp/out", .tar_gz, false);
    defer freeCommandArgv(allocator, tgz_cmd);
    try std.testing.expectEqualStrings("tar", tgz_cmd[0]);
    try std.testing.expectEqualStrings("-xzf", tgz_cmd[1]);

    var list = std.ArrayList([]const u8).empty;
    try list.append(allocator, try allocator.dupe(u8, "tmp"));
    freeCommandList(allocator, &list);
}

test "resolveRoot unwraps single directory only when no top-level files exist" {
    // covers: archive.resolveRoot
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "single/only/sub");
    const single_root = try tmp.dir.realPathFileAlloc(std.testing.io, "single", std.testing.allocator);
    defer std.testing.allocator.free(single_root);

    const unwrapped = try resolveRoot(std.testing.allocator, single_root);
    defer std.testing.allocator.free(unwrapped);
    try std.testing.expect(std.mem.endsWith(u8, unwrapped, "only"));

    try tmp.dir.createDirPath(std.testing.io, "mixed/only");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "mixed/README.md", .data = "hi" });
    const mixed_root = try tmp.dir.realPathFileAlloc(std.testing.io, "mixed", std.testing.allocator);
    defer std.testing.allocator.free(mixed_root);

    const kept_mixed = try resolveRoot(std.testing.allocator, mixed_root);
    defer std.testing.allocator.free(kept_mixed);
    try std.testing.expectEqualStrings(mixed_root, kept_mixed);

    try tmp.dir.createDirPath(std.testing.io, "empty");
    const empty_root = try tmp.dir.realPathFileAlloc(std.testing.io, "empty", std.testing.allocator);
    defer std.testing.allocator.free(empty_root);

    const kept_empty = try resolveRoot(std.testing.allocator, empty_root);
    defer std.testing.allocator.free(kept_empty);
    try std.testing.expectEqualStrings(empty_root, kept_empty);
}

test "ensureDownload and extract invoke runner and skip existing download" {
    // covers: archive.ensureDownload archive.extract
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const dest = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "file.zip" });
    defer std.testing.allocator.free(dest);
    const out_dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "out" });
    defer std.testing.allocator.free(out_dir);

    const fake = runner.TestRunner{ .run = struct {
        fn runFn(alloc: types.Allocator, argv: []const []const u8, _: ?[]const u8, _: runner.RunOptions) types.GenerateAllCodeDocsError!runner.RunResult {
            test_last_len = argv.len;
            const out = try alloc.alloc(u8, 0);
            const err = try alloc.alloc(u8, 0);
            return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .exited = 0 }, .allocator = alloc };
        }
    }.runFn };

    runner.setTestRunner(fake);
    defer runner.setTestRunner(null);
    test_last_len = 0;

    try ensureDownload(std.testing.allocator, "https://example.com/file.zip", dest, .{});
    try std.testing.expect(test_last_len > 0);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.zip", .data = "cached" });
    test_last_len = 0;
    try ensureDownload(std.testing.allocator, "https://example.com/file.zip", dest, .{});
    try std.testing.expectEqual(@as(usize, 0), test_last_len);

    try extract(std.testing.allocator, dest, out_dir, .zip, .{});
    try std.testing.expect(test_last_len > 0);
}

test "pruneCache removes unreferenced archives and ignores non-archive files or missing dir" {
    // covers: archive.pruneCache
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "keep.zip", .data = "ok" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "drop.tar.gz", .data = "no" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "notes.txt", .data = "keep-note" });
    try tmp.dir.createDirPath(std.testing.io, "subdir");

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);

    try pruneCache(std.testing.allocator, base, &.{"keep"});

    const keep_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "keep.zip" });
    defer std.testing.allocator.free(keep_path);
    const drop_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "drop.tar.gz" });
    defer std.testing.allocator.free(drop_path);
    const note_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "notes.txt" });
    defer std.testing.allocator.free(note_path);
    try std.testing.expect(fsutils.fileExists(keep_path));
    try std.testing.expect(!fsutils.fileExists(drop_path));
    try std.testing.expect(fsutils.fileExists(note_path));

    const missing_dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "missing" });
    defer std.testing.allocator.free(missing_dir);
    try pruneCache(std.testing.allocator, missing_dir, &.{});
}

/// Number of arguments captured in the last mock runner call.
var test_last_len: usize = 0;
