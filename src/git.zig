//! Git repository detection, cloning, worktree management, reference inference, and cache pruning.

const std = @import("std");
const types = @import("types.zig");
const fsutils = @import("fsutils.zig");
const paths = @import("paths.zig");
const runner = @import("runner.zig");

/// Git reference information inferred from a repository checkout.
pub const RefInfo = struct {
    /// Reference value (tag or commit).
    ref: []const u8,
    /// Reference kind.
    kind: types.RefKind,
    /// Short commit hash.
    commit_short: []const u8,
    /// Commit subject line.
    commit_subject: []const u8,

    /// Free the three allocated strings (`ref`, `commit_short`, `commit_subject`).
    ///
    /// @param self `RefInfo` instance to deinitialize.
    /// @param allocator Allocator that allocated the fields.
    pub fn deinit(self: RefInfo, allocator: types.Allocator) void {
        allocator.free(self.ref);
        allocator.free(self.commit_short);
        allocator.free(self.commit_subject);
    }
};

/// Execute a `git` command with optional `http.sslVerify=false` and return the `RunResult`.
///
/// @param allocator Allocator for command arguments and process output.
/// @param options Execution options (including `.insecure`).
/// @param git_args Arguments passed to `git` after optional SSL configuration.
/// @return Captured `RunResult` owned by caller.
pub fn runGit(
    allocator: types.Allocator,
    options: runner.RunOptions,
    git_args: []const []const u8,
) types.GenerateAllCodeDocsError!runner.RunResult {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    if (options.insecure) {
        try argv.append(allocator, "-c");
        try argv.append(allocator, "http.sslVerify=false");
    }
    try argv.appendSlice(allocator, git_args);
    return runner.run(allocator, argv.items, null, options);
}

/// Execute a `git` command with optional `http.sslVerify=false` and require exit status 0.
///
/// @param allocator Allocator for command arguments and process output.
/// @param options Execution options (including `.insecure`).
/// @param git_args Arguments passed to `git` after optional SSL configuration.
/// @return Captured `RunResult` owned by caller when exit code is 0.
pub fn runGitChecked(
    allocator: types.Allocator,
    options: runner.RunOptions,
    git_args: []const []const u8,
) types.GenerateAllCodeDocsError!runner.RunResult {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    if (options.insecure) {
        try argv.append(allocator, "-c");
        try argv.append(allocator, "http.sslVerify=false");
    }
    try argv.appendSlice(allocator, git_args);
    return runner.runChecked(allocator, argv.items, null, options);
}

/// Check if a filesystem path contains a `.git` directory or `.git` worktree/submodule file without heap allocation.
///
/// @param path Directory path to inspect.
/// @return `true` if `path/.git` exists as a directory or file.
pub fn isGitRepo(path: []const u8) bool {
    const io = fsutils.defaultIo();
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    defer dir.close(io);

    if (dir.openDir(io, ".git", .{})) |sub| {
        var sub_dir = sub;
        sub_dir.close(io);
        return true;
    } else |_| {}

    if (dir.openFile(io, ".git", .{})) |file| {
        file.close(io);
        return true;
    } else |_| {}

    return false;
}

/// Clone a remote repository into `cache_path` or fetch updates if `cache_path` already exists.
///
/// @param allocator Allocator for command argument construction.
/// @param remote Git remote URL (SSH or HTTPS).
/// @param cache_path Destination directory in cache.
/// @param shallow Whether to limit clone/fetch history to depth 1.
/// @param options Runner execution options.
pub fn ensureClone(
    allocator: types.Allocator,
    remote: []const u8,
    cache_path: []const u8,
    shallow: bool,
    options: runner.RunOptions,
) types.GenerateAllCodeDocsError!void {
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);

    if (fsutils.dirExists(cache_path)) {
        try args.appendSlice(allocator, &.{ "-C", cache_path, "fetch" });
        if (shallow) {
            try args.appendSlice(allocator, &.{ "--depth", "1" });
        }
        try args.appendSlice(allocator, &.{ "--all", "--tags" });
        var result = try runGitChecked(allocator, options, args.items);
        result.deinit();
        return;
    }

    try args.append(allocator, "clone");
    if (shallow) {
        try args.appendSlice(allocator, &.{ "--depth", "1" });
    }
    try args.appendSlice(allocator, &.{ "--no-checkout", remote, cache_path });
    var result = try runGitChecked(allocator, options, args.items);
    result.deinit();
}

/// Create or recreate a detached git worktree at `worktree_path` for `ref` using `--force`.
///
/// @param allocator Allocator for command execution.
/// @param repo_path Source git repository path.
/// @param worktree_path Destination worktree directory path.
/// @param ref Git reference (tag, branch, or commit) to checkout.
/// @param options Runner execution options.
pub fn ensureWorktree(
    allocator: types.Allocator,
    repo_path: []const u8,
    worktree_path: []const u8,
    ref: []const u8,
    options: runner.RunOptions,
) types.GenerateAllCodeDocsError!void {
    try fsutils.ensureEmptyDir(worktree_path);
    var result = try runGitChecked(
        allocator,
        options,
        &.{ "-C", repo_path, "worktree", "add", "--force", "--detach", worktree_path, ref },
    );
    result.deinit();
}

/// Infer reference, short commit hash, and commit subject from a git checkout.
/// Cleans up partial allocations via `errdefer` if any git query fails.
///
/// @param allocator Allocator for returned `RefInfo` strings.
/// @param repo_path Path to the git repository or worktree.
/// @param options Runner execution options.
/// @return Populated `RefInfo` owned by caller.
pub fn inferRef(
    allocator: types.Allocator,
    repo_path: []const u8,
    options: runner.RunOptions,
) types.GenerateAllCodeDocsError!RefInfo {
    const describe = try gitString(allocator, &.{ "-C", repo_path, "describe", "--tags", "--always" }, options);
    errdefer allocator.free(describe);

    const commit_short = try gitString(allocator, &.{ "-C", repo_path, "rev-parse", "--short", "HEAD" }, options);
    errdefer allocator.free(commit_short);

    const commit_subject = try gitString(allocator, &.{ "-C", repo_path, "log", "-1", "--pretty=%s" }, options);
    const kind: types.RefKind = if (looksLikeCommit(describe)) .commit else .tag;

    return RefInfo{
        .ref = describe,
        .kind = kind,
        .commit_short = commit_short,
        .commit_subject = commit_subject,
    };
}

/// Run a git command and return its trimmed standard output as an allocated slice.
///
/// @param allocator Allocator for the output string.
/// @param git_args Arguments to pass to `git`.
/// @param options Runner execution options.
/// @return Trimmed stdout slice owned by caller.
fn gitString(
    allocator: types.Allocator,
    git_args: []const []const u8,
    options: runner.RunOptions,
) types.GenerateAllCodeDocsError![]const u8 {
    var result = try runGitChecked(allocator, options, git_args);
    defer result.deinit();

    const trimmed = std.mem.trim(u8, result.stdout, " \x0a\x0d\x09");
    return allocator.dupe(u8, trimmed);
}

/// Remove cached git clone directories in `cache_dir` not listed in `keep_keys` (preserving `manifest`).
///
/// @param allocator Allocator for temporary path joins.
/// @param cache_dir Cache root directory path.
/// @param keep_keys Slice of cache keys to retain.
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
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, "manifest")) continue;
        if (paths.containsKey(keep_keys, entry.name)) continue;

        const path = try std.Io.Dir.path.join(allocator, &.{ cache_dir, entry.name });
        defer allocator.free(path);
        try std.Io.Dir.cwd().deleteTree(io, path);
    }
}

/// Check if an output from `git describe --tags --always` looks like a raw hexadecimal commit hash (7..40 hex chars).
///
/// @param input String returned by `git describe`.
/// @return `true` if `input` is 7 to 40 hexadecimal characters.
fn looksLikeCommit(input: []const u8) bool {
    if (input.len < 7 or input.len > 40) return false;
    for (input) |ch| {
        if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

test "looksLikeCommit detects valid hex commit hashes and rejects tags or short/long strings" {
    // covers: git.looksLikeCommit
    try std.testing.expect(looksLikeCommit("deadbeef"));
    try std.testing.expect(!looksLikeCommit("short"));
    try std.testing.expect(!looksLikeCommit("v1.0.0-rc1"));
}

test "inferRef parses tags, commits, and frees memory on error without leaking" {
    // covers: git.inferRef git.gitString git.deinit
    const allocator = std.testing.allocator;
    test_call_index = 0;

    const fake_tag = runner.TestRunner{ .run = struct {
        fn runFn(alloc: types.Allocator, _: []const []const u8, _: ?[]const u8, _: runner.RunOptions) types.GenerateAllCodeDocsError!runner.RunResult {
            const outputs = [_][]const u8{ "v1.2.3\x0a", "abc1234\x0a", "subject line\x0a" };
            const out = try alloc.dupe(u8, outputs[test_call_index]);
            test_call_index += 1;
            const err = try alloc.alloc(u8, 0);
            return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .exited = 0 }, .allocator = alloc };
        }
    }.runFn };

    runner.setTestRunner(fake_tag);
    defer runner.setTestRunner(null);

    const info_tag = try inferRef(allocator, "/tmp/repo", .{});
    defer info_tag.deinit(allocator);
    try std.testing.expectEqualStrings("v1.2.3", info_tag.ref);
    try std.testing.expectEqual(types.RefKind.tag, info_tag.kind);
    try std.testing.expectEqualStrings("abc1234", info_tag.commit_short);
    try std.testing.expectEqualStrings("subject line", info_tag.commit_subject);

    test_call_index = 0;
    const fake_commit = runner.TestRunner{ .run = struct {
        fn runFn(alloc: types.Allocator, _: []const []const u8, _: ?[]const u8, _: runner.RunOptions) types.GenerateAllCodeDocsError!runner.RunResult {
            const outputs = [_][]const u8{ "deadbeef1234\x0a", "deadbee\x0a", "initial\x0a" };
            const out = try alloc.dupe(u8, outputs[test_call_index]);
            test_call_index += 1;
            const err = try alloc.alloc(u8, 0);
            return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .exited = 0 }, .allocator = alloc };
        }
    }.runFn };
    runner.setTestRunner(fake_commit);
    const info_commit = try inferRef(allocator, "/tmp/repo", .{});
    defer info_commit.deinit(allocator);
    try std.testing.expectEqual(types.RefKind.commit, info_commit.kind);

    test_call_index = 0;
    const fake_fail = runner.TestRunner{ .run = struct {
        fn runFn(alloc: types.Allocator, _: []const []const u8, _: ?[]const u8, _: runner.RunOptions) types.GenerateAllCodeDocsError!runner.RunResult {
            test_call_index += 1;
            if (test_call_index == 3) {
                return error.CommandFailed;
            }
            const out = try alloc.dupe(u8, "deadbeef\x0a");
            const err = try alloc.alloc(u8, 0);
            return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .exited = 0 }, .allocator = alloc };
        }
    }.runFn };
    runner.setTestRunner(fake_fail);
    try std.testing.expectError(error.CommandFailed, inferRef(allocator, "/tmp/repo", .{}));
}

test "ensureClone handles fresh clone, existing cache fetch, shallow, and insecure flags" {
    // covers: git.ensureClone git.runGit git.runGitChecked
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const cache_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "cache" });
    defer std.testing.allocator.free(cache_path);

    const fake = runner.TestRunner{ .run = struct {
        fn runFn(alloc: types.Allocator, argv: []const []const u8, _: ?[]const u8, _: runner.RunOptions) types.GenerateAllCodeDocsError!runner.RunResult {
            test_last_len = argv.len;
            for (argv, 0..) |arg, idx| {
                if (idx < test_last_argv.len) test_last_argv[idx] = arg;
            }
            const out = try alloc.alloc(u8, 0);
            const err = try alloc.alloc(u8, 0);
            return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .exited = 0 }, .allocator = alloc };
        }
    }.runFn };

    runner.setTestRunner(fake);
    defer runner.setTestRunner(null);

    try ensureClone(std.testing.allocator, "git@github.com:org/repo.git", cache_path, false, .{ .insecure = true });
    try std.testing.expectEqualStrings("git", test_last_argv[0]);
    try std.testing.expectEqualStrings("-c", test_last_argv[1]);
    try std.testing.expectEqualStrings("http.sslVerify=false", test_last_argv[2]);
    try std.testing.expectEqualStrings("clone", test_last_argv[3]);

    try ensureClone(std.testing.allocator, "git@github.com:org/repo.git", cache_path, true, .{});
    try std.testing.expectEqualStrings("clone", test_last_argv[1]);
    try std.testing.expectEqualStrings("--depth", test_last_argv[2]);
    try std.testing.expectEqualStrings("1", test_last_argv[3]);

    try tmp.dir.createDirPath(std.testing.io, "cache");
    try ensureClone(std.testing.allocator, "git@github.com:org/repo.git", cache_path, true, .{});
    try std.testing.expectEqualStrings("fetch", test_last_argv[3]);
    try std.testing.expectEqualStrings("--depth", test_last_argv[4]);

    var direct = try runGit(std.testing.allocator, .{ .insecure = true }, &.{"status"});
    defer direct.deinit();
    try std.testing.expectEqualStrings("status", test_last_argv[3]);
}

test "pruneCache removes unused clones, preserves manifest, and ignores missing cache dir" {
    // covers: git.pruneCache
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "keep");
    try tmp.dir.createDirPath(std.testing.io, "drop");
    try tmp.dir.createDirPath(std.testing.io, "manifest");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.zip", .data = "skip" });

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);

    try pruneCache(std.testing.allocator, base, &.{"keep"});

    const keep_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "keep" });
    defer std.testing.allocator.free(keep_path);
    const drop_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "drop" });
    defer std.testing.allocator.free(drop_path);
    const manifest_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "manifest" });
    defer std.testing.allocator.free(manifest_path);
    try std.testing.expect(fsutils.dirExists(keep_path));
    try std.testing.expect(!fsutils.dirExists(drop_path));
    try std.testing.expect(fsutils.dirExists(manifest_path));

    const missing_dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "no-such-cache" });
    defer std.testing.allocator.free(missing_dir);
    try pruneCache(std.testing.allocator, missing_dir, &.{});
}

test "isGitRepo detects .git directory, .git file, and non-repo" {
    // covers: git.isGitRepo
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo_dir/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo_file");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo_file/.git", .data = "gitdir: ../.git/worktrees/x" });
    try tmp.dir.createDirPath(std.testing.io, "plain");

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);

    const p_dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "repo_dir" });
    defer std.testing.allocator.free(p_dir);
    const p_file = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "repo_file" });
    defer std.testing.allocator.free(p_file);
    const p_plain = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "plain" });
    defer std.testing.allocator.free(p_plain);
    const p_missing = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "missing" });
    defer std.testing.allocator.free(p_missing);

    try std.testing.expect(isGitRepo(p_dir));
    try std.testing.expect(isGitRepo(p_file));
    try std.testing.expect(!isGitRepo(p_plain));
    try std.testing.expect(!isGitRepo(p_missing));
}

test "ensureWorktree calls git worktree add --force --detach" {
    // covers: git.ensureWorktree
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.createDirPath(std.testing.io, "worktree");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "worktree/old.txt", .data = "old" });

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const repo_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "repo" });
    defer std.testing.allocator.free(repo_path);
    const worktree_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "worktree" });
    defer std.testing.allocator.free(worktree_path);

    const fake = runner.TestRunner{ .run = struct {
        fn runFn(alloc: types.Allocator, argv: []const []const u8, _: ?[]const u8, _: runner.RunOptions) types.GenerateAllCodeDocsError!runner.RunResult {
            test_last_len = argv.len;
            for (argv, 0..) |arg, idx| {
                if (idx < test_last_argv.len) test_last_argv[idx] = arg;
            }
            const out = try alloc.alloc(u8, 0);
            const err = try alloc.alloc(u8, 0);
            return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .exited = 0 }, .allocator = alloc };
        }
    }.runFn };

    runner.setTestRunner(fake);
    defer runner.setTestRunner(null);
    test_last_len = 0;

    try ensureWorktree(std.testing.allocator, repo_path, worktree_path, "HEAD", .{});

    try std.testing.expectEqualStrings("worktree", test_last_argv[3]);
    try std.testing.expectEqualStrings("add", test_last_argv[4]);
    try std.testing.expectEqualStrings("--force", test_last_argv[5]);
    try std.testing.expectEqualStrings("--detach", test_last_argv[6]);
}

/// Captured argument array for git unit tests.
var test_last_argv: [12][]const u8 = undefined;
/// Number of captured arguments in `test_last_argv`.
var test_last_len: usize = 0;
/// Call counter for multi-step `inferRef` tests.
var test_call_index: usize = 0;
