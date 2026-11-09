//! Deployment of generated documentation sites to a GitHub Pages git branch via temporary worktrees.

const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");
const fsutils = @import("fsutils.zig");
const git = @import("git.zig");
const runner = @import("runner.zig");

/// Options for deploying the generated site.
pub const DeployOptions = struct {
    /// Git remote name.
    remote: []const u8 = "origin",
    /// Target branch for deployment.
    branch: []const u8 = "gh-pages",
    /// Commit message to use.
    message: []const u8 = "generate-all-code-docs deploy",
    /// Dry-run without modifying git state.
    dry_run: bool = false,
    /// Verbose command logging.
    verbose: bool = false,
    /// Emit JSON logs.
    json: bool = false,
    /// Skip SSL verification for git operations.
    insecure: bool = false,
    /// Preserve deploy branch contents instead of wiping before copy.
    preserve_history: bool = false,
    /// Optional log file for runner output.
    log_file: ?std.Io.File = null,
};

/// Deploy the site output directory (`cfg.site.output_dir`) to a GitHub Pages branch.
///
/// @param allocator Allocator for path joins and subprocess execution.
/// @param cfg Loaded `Config` containing `site.output_dir` and `work_dir`.
/// @param options Deployment options (`remote`, `branch`, `message`, `dry_run`, etc.).
/// @param stdout Concrete `*std.Io.Writer` for status and JSON event output.
/// @param stderr Concrete `*std.Io.Writer` for diagnostic error output.
pub fn deploy(
    allocator: types.Allocator,
    cfg: config.Config,
    options: DeployOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) types.GenerateAllCodeDocsError!void {
    const io = fsutils.defaultIo();
    if (!fsutils.dirExists(cfg.site.output_dir)) {
        try stderr.print("deploy error: output directory '{s}' is missing\x0a", .{cfg.site.output_dir});
        return error.OutputDirMissing;
    }

    try types.writeLogEvent(
        stdout,
        options.json,
        .{ .deploy_start = .{
            .output_dir = cfg.site.output_dir,
            .remote = options.remote,
            .branch = options.branch,
            .dry_run = options.dry_run,
        } },
    );

    if (options.dry_run) return;

    const run_options = runner.RunOptions{
        .verbose = options.verbose,
        .log_file = options.log_file,
        .json = options.json,
        .insecure = options.insecure,
    };

    const deploy_dir = try std.Io.Dir.path.join(allocator, &.{ cfg.work_dir, "deploy" });
    defer allocator.free(deploy_dir);
    try fsutils.ensureDir(cfg.work_dir);

    if (fsutils.dirExists(deploy_dir)) {
        var rm_res = try git.runGit(allocator, run_options, &.{ "worktree", "remove", "--force", deploy_dir });
        rm_res.deinit();
        std.Io.Dir.cwd().deleteTree(io, deploy_dir) catch {};
    }

    const remote_ref = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ options.remote, options.branch });
    defer allocator.free(remote_ref);

    var fetch_res = try git.runGit(allocator, run_options, &.{ "fetch", options.remote, options.branch });
    const fetched = fetch_res.term == .exited and fetch_res.term.exited == 0;
    fetch_res.deinit();

    if (fetched) {
        var wt_res = try git.runGitChecked(allocator, run_options, &.{ "worktree", "add", "--force", "-B", options.branch, deploy_dir, remote_ref });
        wt_res.deinit();
    } else {
        var wt_res = try git.runGitChecked(allocator, run_options, &.{ "worktree", "add", "--force", "--detach", deploy_dir });
        wt_res.deinit();
        var co_res = try git.runGitChecked(allocator, run_options, &.{ "-C", deploy_dir, "checkout", "--orphan", options.branch });
        co_res.deinit();
    }
    defer {
        var cleanup_res = git.runGit(allocator, run_options, &.{ "worktree", "remove", "--force", deploy_dir }) catch null;
        if (cleanup_res) |*res| res.deinit();
    }

    if (!options.preserve_history) {
        var rm_all = try git.runGit(allocator, run_options, &.{ "-C", deploy_dir, "rm", "-rf", "." });
        rm_all.deinit();
        var clean_all = try git.runGit(allocator, run_options, &.{ "-C", deploy_dir, "clean", "-fdx" });
        clean_all.deinit();
    }

    try fsutils.copyDir(allocator, cfg.site.output_dir, deploy_dir);
    const nojekyll = try std.Io.Dir.path.join(allocator, &.{ deploy_dir, ".nojekyll" });
    defer allocator.free(nojekyll);
    try fsutils.writeFile(nojekyll, "");

    var add_res = try git.runGitChecked(allocator, run_options, &.{ "-C", deploy_dir, "add", "-A" });
    add_res.deinit();

    var status = try git.runGitChecked(allocator, run_options, &.{ "-C", deploy_dir, "status", "--porcelain" });
    defer status.deinit();

    const trimmed = std.mem.trim(u8, status.stdout, " \x0a\x0d\x09");
    if (trimmed.len == 0) {
        try types.writeLogEvent(
            stdout,
            options.json,
            .{ .deploy_status = .{ .status = "no-changes" } },
        );
        return;
    }

    var commit_res = try git.runGitChecked(allocator, run_options, &.{ "-C", deploy_dir, "commit", "-m", options.message });
    commit_res.deinit();
    if (fetched) {
        var push_res = try git.runGitChecked(allocator, run_options, &.{ "-C", deploy_dir, "push", options.remote, options.branch });
        push_res.deinit();
    } else {
        var push_u = try git.runGitChecked(allocator, run_options, &.{ "-C", deploy_dir, "push", "-u", options.remote, options.branch });
        push_u.deinit();
    }
}

test "deploy fails when output dir missing and writes diagnostic to stderr" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const missing = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "missing" });
    defer std.testing.allocator.free(missing);

    var repos = [_]config.Repo{};
    const cfg = config.Config{
        .site = .{ .username = "sam", .path = "docs", .output_dir = missing },
        .work_dir = base,
        .repos = repos[0..],
    };

    var out_buf: [256]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var err_writer = std.Io.Writer.fixed(&err_buf);
    try std.testing.expectError(error.OutputDirMissing, deploy(std.testing.allocator, cfg, .{}, &out_writer, &err_writer));
    try std.testing.expect(std.mem.containsAtLeast(u8, err_writer.buffered(), 1, "deploy error"));
}

test "deploy handles dry-run, existing deploy dir, fetched branch, no-changes, and json mode" {
    // covers: deploy.deploy
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "site");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "site/index.html", .data = "ok" });
    try tmp.dir.createDirPath(std.testing.io, "work/deploy");

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const site_dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "site" });
    defer std.testing.allocator.free(site_dir);
    const work_dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "work" });
    defer std.testing.allocator.free(work_dir);

    var repos = [_]config.Repo{};
    const cfg = config.Config{
        .site = .{ .username = "sam", .path = "docs", .output_dir = site_dir },
        .work_dir = work_dir,
        .repos = repos[0..],
    };

    // 1. Dry-run in JSON mode
    var dry_buf: [512]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var dry_writer = std.Io.Writer.fixed(&dry_buf);
    var err_writer = std.Io.Writer.fixed(&err_buf);
    try deploy(std.testing.allocator, cfg, .{ .dry_run = true, .json = true }, &dry_writer, &err_writer);
    try std.testing.expect(std.mem.containsAtLeast(u8, dry_writer.buffered(), 1, "\x22dry_run\x22:true"));

    // 2. Full deploy when remote branch exists and has changes
    const fake_changes = runner.TestRunner{ .run = struct {
        fn runFn(alloc: types.Allocator, argv: []const []const u8, _: ?[]const u8, _: runner.RunOptions) types.GenerateAllCodeDocsError!runner.RunResult {
            for (argv) |arg| {
                if (std.mem.eql(u8, arg, "push")) test_saw_push = true;
                if (std.mem.eql(u8, arg, "-u")) test_saw_push_u = true;
                if (std.mem.eql(u8, arg, "rm")) test_saw_rm = true;
                if (std.mem.eql(u8, arg, "clean")) test_saw_clean = true;
            }
            for (argv) |arg| {
                if (std.mem.eql(u8, arg, "--porcelain")) {
                    const out = try alloc.dupe(u8, " M index.html\x0a");
                    const err = try alloc.alloc(u8, 0);
                    return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .exited = 0 }, .allocator = alloc };
                }
            }
            const out = try alloc.alloc(u8, 0);
            const err = try alloc.alloc(u8, 0);
            return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .exited = 0 }, .allocator = alloc };
        }
    }.runFn };

    runner.setTestRunner(fake_changes);
    defer runner.setTestRunner(null);
    test_saw_push = false;
    test_saw_push_u = false;
    test_saw_rm = false;
    test_saw_clean = false;

    var out_buf: [512]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    try deploy(std.testing.allocator, cfg, .{}, &out_writer, &err_writer);
    try std.testing.expect(test_saw_push);
    try std.testing.expect(!test_saw_push_u);
    try std.testing.expect(test_saw_rm);
    try std.testing.expect(test_saw_clean);

    // 3. No changes branch
    const fake_no_changes = runner.TestRunner{ .run = struct {
        fn runFn(alloc: types.Allocator, _: []const []const u8, _: ?[]const u8, _: runner.RunOptions) types.GenerateAllCodeDocsError!runner.RunResult {
            const out = try alloc.alloc(u8, 0);
            const err = try alloc.alloc(u8, 0);
            return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .exited = 0 }, .allocator = alloc };
        }
    }.runFn };
    runner.setTestRunner(fake_no_changes);
    var nc_buf: [512]u8 = undefined;
    var nc_writer = std.Io.Writer.fixed(&nc_buf);
    try deploy(std.testing.allocator, cfg, .{ .preserve_history = true }, &nc_writer, &err_writer);
    try std.testing.expect(std.mem.containsAtLeast(u8, nc_writer.buffered(), 1, "No changes to deploy."));
}

test "deploy creates orphan branch when fetch fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "site");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "site/index.html", .data = "ok" });

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const site_dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "site" });
    defer std.testing.allocator.free(site_dir);
    const work_dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "work" });
    defer std.testing.allocator.free(work_dir);

    var repos = [_]config.Repo{};
    const cfg = config.Config{
        .site = .{ .username = "sam", .path = "docs", .output_dir = site_dir },
        .work_dir = work_dir,
        .repos = repos[0..],
    };

    const fake = runner.TestRunner{ .run = struct {
        fn runFn(alloc: types.Allocator, argv: []const []const u8, _: ?[]const u8, _: runner.RunOptions) types.GenerateAllCodeDocsError!runner.RunResult {
            for (argv) |arg| {
                if (std.mem.eql(u8, arg, "push")) test_saw_push = true;
                if (std.mem.eql(u8, arg, "-u")) test_saw_push_u = true;
            }
            if (argv.len >= 2 and std.mem.eql(u8, argv[1], "fetch")) {
                const out = try alloc.alloc(u8, 0);
                const err = try alloc.alloc(u8, 0);
                return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .exited = 1 }, .allocator = alloc };
            }
            for (argv) |arg| {
                if (std.mem.eql(u8, arg, "--porcelain")) {
                    const out = try alloc.dupe(u8, " M index.html\x0a");
                    const err = try alloc.alloc(u8, 0);
                    return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .exited = 0 }, .allocator = alloc };
                }
            }
            const out = try alloc.alloc(u8, 0);
            const err = try alloc.alloc(u8, 0);
            return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .exited = 0 }, .allocator = alloc };
        }
    }.runFn };

    runner.setTestRunner(fake);
    defer runner.setTestRunner(null);
    test_saw_push = false;
    test_saw_push_u = false;

    var out_buf: [256]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var err_writer = std.Io.Writer.fixed(&err_buf);
    try deploy(std.testing.allocator, cfg, .{}, &out_writer, &err_writer);
    try std.testing.expect(test_saw_push);
    try std.testing.expect(test_saw_push_u);
}

/// Whether `push` was observed in the test runner.
var test_saw_push: bool = false;
/// Whether `-u` was observed in the test runner.
var test_saw_push_u: bool = false;
/// Whether `rm` was observed in the test runner.
var test_saw_rm: bool = false;
/// Whether `clean` was observed in the test runner.
var test_saw_clean: bool = false;
