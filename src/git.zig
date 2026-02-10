const std = @import("std");
const types = @import("types.zig");
const fsutils = @import("fsutils.zig");
const runner = @import("runner.zig");

/// Git reference information inferred from a repository.
pub const RefInfo = struct {
    /// Reference value (tag or commit).
    ref: []const u8,
    /// Reference kind.
    kind: types.RefKind,
    /// Short commit hash.
    commit_short: []const u8,
    /// Commit subject line.
    commit_subject: []const u8,
};

/// Check if a path looks like a git repository.
pub fn isGitRepo(allocator: types.Allocator, path: []const u8) bool {
    const git_path = std.fs.path.join(allocator, &.{ path, ".git" }) catch return false;
    defer allocator.free(git_path);
    return fsutils.dirExists(git_path) or fsutils.fileExists(git_path);
}

/// Clone or update a remote repository in the cache.
pub fn ensureClone(
    allocator: types.Allocator,
    remote: []const u8,
    cache_path: []const u8,
    shallow: bool,
    options: runner.RunOptions,
) !void {
    if (fsutils.dirExists(cache_path)) {
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(allocator);
        try argv.append(allocator, "git");
        if (options.insecure) {
            try argv.append(allocator, "-c");
            try argv.append(allocator, "http.sslVerify=false");
        }
        try argv.append(allocator, "-C");
        try argv.append(allocator, cache_path);
        try argv.append(allocator, "fetch");
        if (shallow) {
            try argv.append(allocator, "--depth");
            try argv.append(allocator, "1");
        }
        try argv.append(allocator, "--all");
        try argv.append(allocator, "--tags");
        var result = try runner.runChecked(allocator, argv.items, null, options);
        result.deinit();
        return;
    }

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    if (options.insecure) {
        try argv.append(allocator, "-c");
        try argv.append(allocator, "http.sslVerify=false");
    }
    try argv.append(allocator, "clone");
    if (shallow) {
        try argv.append(allocator, "--depth");
        try argv.append(allocator, "1");
    }
    try argv.append(allocator, "--no-checkout");
    try argv.append(allocator, remote);
    try argv.append(allocator, cache_path);
    var result = try runner.runChecked(allocator, argv.items, null, options);
    result.deinit();
}

/// Create a detached worktree at the requested reference.
pub fn ensureWorktree(allocator: types.Allocator, repo_path: []const u8, worktree_path: []const u8, ref: []const u8, options: runner.RunOptions) !void {
    try fsutils.ensureEmptyDir(worktree_path);
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    if (options.insecure) {
        try argv.append(allocator, "-c");
        try argv.append(allocator, "http.sslVerify=false");
    }
    try argv.append(allocator, "-C");
    try argv.append(allocator, repo_path);
    try argv.append(allocator, "worktree");
    try argv.append(allocator, "add");
    try argv.append(allocator, "--detach");
    try argv.append(allocator, worktree_path);
    try argv.append(allocator, ref);
    var result = try runner.runChecked(allocator, argv.items, null, options);
    result.deinit();
}

/// Infer a reference and commit metadata from a git repository.
pub fn inferRef(allocator: types.Allocator, repo_path: []const u8, options: runner.RunOptions) !RefInfo {
    const describe = try gitString(allocator, options.insecure, &.{ "-C", repo_path, "describe", "--tags", "--always" }, options);
    const commit_short = try gitString(allocator, options.insecure, &.{ "-C", repo_path, "rev-parse", "--short", "HEAD" }, options);
    const commit_subject = try gitString(allocator, options.insecure, &.{ "-C", repo_path, "log", "-1", "--pretty=%s" }, options);
    const kind: types.RefKind = if (looksLikeCommit(describe)) .commit else .tag;

    return RefInfo{
        .ref = describe,
        .kind = kind,
        .commit_short = commit_short,
        .commit_subject = commit_subject,
    };
}

fn gitString(allocator: types.Allocator, insecure: bool, args: []const []const u8, options: runner.RunOptions) ![]const u8 {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    if (insecure) {
        try argv.append(allocator, "-c");
        try argv.append(allocator, "http.sslVerify=false");
    }
    try argv.appendSlice(allocator, args);

    var result = try runner.runChecked(allocator, argv.items, null, options);
    defer result.deinit();

    const trimmed = std.mem.trim(u8, result.stdout, " \n\r\t");
    return allocator.dupe(u8, trimmed);
}

/// Remove cached git clones not referenced by the provided keys.
pub fn pruneCache(allocator: types.Allocator, cache_dir: []const u8, keep_keys: []const []const u8) !void {
    var dir = std.fs.cwd().openDir(cache_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, "manifest")) continue;
        if (containsKey(keep_keys, entry.name)) continue;

        const path = try std.fs.path.join(allocator, &.{ cache_dir, entry.name });
        defer allocator.free(path);
        try std.fs.cwd().deleteTree(path);
    }
}

fn containsKey(keys: []const []const u8, key: []const u8) bool {
    for (keys) |item| {
        if (std.mem.eql(u8, item, key)) return true;
    }
    return false;
}

fn looksLikeCommit(input: []const u8) bool {
    if (input.len < 7 or input.len > 40) return false;
    for (input) |ch| {
        if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

test "looksLikeCommit detects hex" {
    try std.testing.expect(looksLikeCommit("deadbeef"));
    try std.testing.expect(!looksLikeCommit("v1.0.0"));
}

test "inferRef uses git outputs" {
    // covers: git.inferRef
    const allocator = std.testing.allocator;
    test_call_index = 0;

    const fake = runner.TestRunner{ .run = struct {
        fn run(alloc: types.Allocator, _: []const []const u8, _: ?[]const u8, _: runner.RunOptions) anyerror!runner.RunResult {
            const outputs = [_][]const u8{ "v1.2.3\n", "abc123\n", "subject line\n" };
            const out = try alloc.dupe(u8, outputs[test_call_index]);
            test_call_index += 1;
            const err = try alloc.alloc(u8, 0);
            return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .Exited = 0 }, .allocator = alloc };
        }
    }.run };

    runner.setTestRunner(fake);
    defer runner.setTestRunner(null);

    const info = try inferRef(allocator, "/tmp/repo", .{});
    try std.testing.expectEqualStrings("v1.2.3", info.ref);
    try std.testing.expectEqual(types.RefKind.tag, info.kind);
    try std.testing.expectEqualStrings("abc123", info.commit_short);
    try std.testing.expectEqualStrings("subject line", info.commit_subject);
    allocator.free(info.ref);
    allocator.free(info.commit_short);
    allocator.free(info.commit_subject);
}

test "ensureClone calls git clone when cache missing" {
    // covers: git.ensureClone
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const cache_path = try std.fs.path.join(std.testing.allocator, &.{ base, "cache" });
    defer std.testing.allocator.free(cache_path);

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

    runner.setTestRunner(fake);
    defer runner.setTestRunner(null);
    test_last_len = 0;

    try ensureClone(std.testing.allocator, "git@github.com:org/repo.git", cache_path, false, .{});
    try std.testing.expectEqualStrings("git", test_last_argv[0]);
    try std.testing.expectEqualStrings("clone", test_last_argv[1]);
    try std.testing.expect(test_last_len > 0);
}

test "ensureClone uses depth for shallow" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const cache_path = try std.fs.path.join(std.testing.allocator, &.{ base, "cache" });
    defer std.testing.allocator.free(cache_path);

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

    runner.setTestRunner(fake);
    defer runner.setTestRunner(null);
    test_last_len = 0;

    try ensureClone(std.testing.allocator, "git@github.com:org/repo.git", cache_path, true, .{});
    var saw_depth = false;
    var saw_one = false;
    for (test_last_argv[0..test_last_len]) |arg| {
        if (std.mem.eql(u8, arg, "--depth")) saw_depth = true;
        if (std.mem.eql(u8, arg, "1")) saw_one = true;
    }
    try std.testing.expect(saw_depth);
    try std.testing.expect(saw_one);
}

test "pruneCache removes unused clones" {
    // covers: git.pruneCache
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("keep");
    try tmp.dir.makePath("drop");
    try tmp.dir.makePath("manifest");

    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);

    try pruneCache(std.testing.allocator, base, &.{ "keep" });

    const keep_path = try std.fs.path.join(std.testing.allocator, &.{ base, "keep" });
    defer std.testing.allocator.free(keep_path);
    const drop_path = try std.fs.path.join(std.testing.allocator, &.{ base, "drop" });
    defer std.testing.allocator.free(drop_path);
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ base, "manifest" });
    defer std.testing.allocator.free(manifest_path);
    try std.testing.expect(fsutils.dirExists(keep_path));
    try std.testing.expect(!fsutils.dirExists(drop_path));
    try std.testing.expect(fsutils.dirExists(manifest_path));
}

test "isGitRepo detects .git directory" {
    // covers: git.isGitRepo
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("repo/.git");
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "repo");
    defer std.testing.allocator.free(path);

    try std.testing.expect(isGitRepo(std.testing.allocator, path));
}

test "ensureWorktree calls git worktree add" {
    // covers: git.ensureWorktree
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("repo");
    try tmp.dir.makePath("worktree");
    try tmp.dir.writeFile(.{ .sub_path = "worktree/old.txt", .data = "old" });

    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const repo_path = try std.fs.path.join(std.testing.allocator, &.{ base, "repo" });
    defer std.testing.allocator.free(repo_path);
    const worktree_path = try std.fs.path.join(std.testing.allocator, &.{ base, "worktree" });
    defer std.testing.allocator.free(worktree_path);

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

    runner.setTestRunner(fake);
    defer runner.setTestRunner(null);
    test_last_len = 0;

    try ensureWorktree(std.testing.allocator, repo_path, worktree_path, "HEAD", .{});

    var saw_worktree = false;
    var saw_add = false;
    var saw_detach = false;
    for (test_last_argv[0..test_last_len]) |arg| {
        if (std.mem.eql(u8, arg, "worktree")) saw_worktree = true;
        if (std.mem.eql(u8, arg, "add")) saw_add = true;
        if (std.mem.eql(u8, arg, "--detach")) saw_detach = true;
    }
    try std.testing.expect(saw_worktree);
    try std.testing.expect(saw_add);
    try std.testing.expect(saw_detach);
}

var test_last_argv: [8][]const u8 = undefined;
var test_last_len: usize = 0;
var test_call_index: usize = 0;
