const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");
const fsutils = @import("fsutils.zig");
const runner = @import("runner.zig");

/// Options for deploying the generated site.
pub const DeployOptions = struct {
    /// Git remote to push to.
    remote: []const u8 = "origin",
    /// Branch name to publish.
    branch: []const u8 = "gh-pages",
    /// Commit message to use for the deploy commit.
    message: []const u8 = "docforge deploy",
    /// Skip filesystem and git mutations.
    dry_run: bool = false,
    /// Enable verbose logging.
    verbose: bool = false,
    /// Optional log file for runner output.
    log_file: ?std.fs.File = null,
    /// Emit JSON logs for deploy output.
    json: bool = false,
    /// Skip SSL verification for git commands.
    insecure: bool = false,
    /// Preserve history by accumulating output instead of wiping.
    preserve_history: bool = false,
};

/// Deploy the site output directory to the requested GitHub Pages branch.
pub fn deploy(
    allocator: types.Allocator,
    cfg: config.Config,
    config_dir: []const u8,
    options: DeployOptions,
    stdout: anytype,
    stderr: anytype,
) !void {
    _ = stderr;
    if (!fsutils.dirExists(cfg.site.output_dir)) {
        return error.OutputDirMissing;
    }

    const run_options = runner.RunOptions{
        .verbose = options.verbose,
        .log_file = options.log_file,
        .json = options.json,
        .insecure = options.insecure,
    };
    const repo_root = try gitRoot(allocator, config_dir, options.insecure, run_options);
    defer allocator.free(repo_root);

    try logEvent(stdout, options.json, .{
        .event = "deploy",
        .output_dir = cfg.site.output_dir,
        .remote = options.remote,
        .branch = options.branch,
        .dry_run = options.dry_run,
    }, "Deploy {s} -> {s}/{s}\n", .{ cfg.site.output_dir, options.remote, options.branch });

    const work_base = try std.fs.path.join(allocator, &.{ cfg.work_dir, "deploy" });
    defer allocator.free(work_base);
    if (!options.dry_run) {
        try fsutils.ensureDir(work_base);
    }

    const worktree_path = try std.fs.path.join(allocator, &.{ work_base, options.branch });
    defer allocator.free(worktree_path);

    if (!options.dry_run and fsutils.dirExists(worktree_path)) {
        var remove = try gitRunChecked(allocator, options.insecure, run_options, &.{ "-C", repo_root, "worktree", "remove", "--force", worktree_path });
        remove.deinit();
    }

    if (!options.dry_run) {
        if (gitRun(allocator, options.insecure, run_options, &.{ "-C", repo_root, "fetch", options.remote, options.branch }) catch null) |result| {
            var mutable = result;
            mutable.deinit();
        }
    }

    const remote_ref = try std.mem.concat(allocator, u8, &.{ "refs/remotes/", options.remote, "/", options.branch });
    defer allocator.free(remote_ref);

    const remote_exists = if (options.dry_run) false else try gitRefExists(allocator, repo_root, remote_ref, options.insecure, run_options);

    if (!options.dry_run) {
        var remove_worktree = false;
        defer if (remove_worktree) {
            if (gitRun(allocator, options.insecure, run_options, &.{ "-C", repo_root, "worktree", "remove", "--force", worktree_path }) catch null) |result| {
                var mutable = result;
                mutable.deinit();
            }
        };

        if (remote_exists) {
            const remote_branch = try std.mem.concat(allocator, u8, &.{ options.remote, "/", options.branch });
            defer allocator.free(remote_branch);
            var result = try gitRunChecked(
                allocator,
                options.insecure,
                run_options,
                &.{ "-C", repo_root, "worktree", "add", "-B", options.branch, worktree_path, remote_branch },
            );
            result.deinit();
        } else {
            var result = try gitRunChecked(
                allocator,
                options.insecure,
                run_options,
                &.{ "-C", repo_root, "worktree", "add", "--detach", worktree_path },
            );
            result.deinit();
            var orphan = try gitRunChecked(
                allocator,
                options.insecure,
                run_options,
                &.{ "-C", worktree_path, "checkout", "--orphan", options.branch },
            );
            orphan.deinit();
        }

        remove_worktree = true;
        try fsutils.ensureDir(worktree_path);

        if (!options.preserve_history) {
            if (gitRun(allocator, options.insecure, run_options, &.{ "-C", worktree_path, "rm", "-rf", "." }) catch null) |result| {
                var mutable = result;
                mutable.deinit();
            }
            if (gitRun(allocator, options.insecure, run_options, &.{ "-C", worktree_path, "clean", "-fdx" }) catch null) |result| {
                var mutable = result;
                mutable.deinit();
            }
        }

        try fsutils.copyDir(allocator, cfg.site.output_dir, worktree_path);

        var add = try gitRunChecked(allocator, options.insecure, run_options, &.{ "-C", worktree_path, "add", "-A" });
        add.deinit();

        var status = try gitRunChecked(allocator, options.insecure, run_options, &.{ "-C", worktree_path, "status", "--porcelain" });
        defer status.deinit();
        const changed = std.mem.trim(u8, status.stdout, " \n\r\t").len > 0;

        if (!changed) {
            try logEvent(stdout, options.json, .{ .event = "deploy", .status = "no-changes" }, "No changes to deploy.\n", .{});
            return;
        }

        var commit = try gitRunChecked(allocator, options.insecure, run_options, &.{ "-C", worktree_path, "commit", "-m", options.message });
        commit.deinit();

        if (remote_exists) {
            var push = try gitRunChecked(allocator, options.insecure, run_options, &.{ "-C", worktree_path, "push", options.remote, options.branch });
            push.deinit();
        } else {
            var push = try gitRunChecked(allocator, options.insecure, run_options, &.{ "-C", worktree_path, "push", "-u", options.remote, options.branch });
            push.deinit();
        }
    }
}

fn gitRoot(allocator: types.Allocator, dir: []const u8, insecure: bool, options: runner.RunOptions) ![]const u8 {
    var result = try gitRunChecked(allocator, insecure, options, &.{ "-C", dir, "rev-parse", "--show-toplevel" });
    defer result.deinit();
    const trimmed = std.mem.trim(u8, result.stdout, " \n\r\t");
    return allocator.dupe(u8, trimmed);
}

fn gitRefExists(allocator: types.Allocator, repo_root: []const u8, ref: []const u8, insecure: bool, options: runner.RunOptions) !bool {
    var result = try gitRun(allocator, insecure, options, &.{ "-C", repo_root, "show-ref", "--verify", "--quiet", ref });
    defer result.deinit();
    return result.term == .Exited and result.term.Exited == 0;
}

fn gitRunChecked(allocator: types.Allocator, insecure: bool, options: runner.RunOptions, args: []const []const u8) !runner.RunResult {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    if (insecure) {
        try argv.append(allocator, "-c");
        try argv.append(allocator, "http.sslVerify=false");
    }
    try argv.appendSlice(allocator, args);
    return runner.runChecked(allocator, argv.items, null, options);
}

fn gitRun(allocator: types.Allocator, insecure: bool, options: runner.RunOptions, args: []const []const u8) !runner.RunResult {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    if (insecure) {
        try argv.append(allocator, "-c");
        try argv.append(allocator, "http.sslVerify=false");
    }
    try argv.appendSlice(allocator, args);
    return runner.run(allocator, argv.items, null, options);
}

fn logEvent(writer: anytype, json: bool, value: anytype, comptime fmt: []const u8, args: anytype) !void {
    if (json) {
        const json_line = try std.json.Stringify.valueAlloc(std.heap.page_allocator, value, .{});
        defer std.heap.page_allocator.free(json_line);
        try writer.writeAll(json_line);
        try writer.writeAll("\n");
        return;
    }
    if (fmt.len > 0) {
        try writer.print(fmt, args);
    }
}

test "deploy uses worktree flow when remote exists" {
    // covers: deploy.deploy
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("repo/site");
    try tmp.dir.writeFile(.{ .sub_path = "repo/site/index.html", .data = "ok" });

    const repo_root = try tmp.dir.realpathAlloc(allocator, "repo");
    defer allocator.free(repo_root);
    const site_dir = try std.fs.path.join(allocator, &.{ repo_root, "site" });
    defer allocator.free(site_dir);
    const work_dir = try std.fs.path.join(allocator, &.{ repo_root, ".docforge", "work" });
    defer allocator.free(work_dir);

    const cfg = config.Config{
        .site = .{ .username = "sam", .path = "docs", .output_dir = site_dir },
        .cache_dir = ".docforge/cache",
        .work_dir = work_dir,
        .tool_templates = null,
        .repos = &.{},
    };

    test_last_len = 0;
    test_saw_push = false;
    test_saw_push_u = false;

    const fake = runner.TestRunner{ .run = struct {
        fn run(alloc: types.Allocator, argv: []const []const u8, _: ?[]const u8, _: runner.RunOptions) anyerror!runner.RunResult {
            test_last_len = argv.len;
            for (argv, 0..) |arg, idx| {
                if (idx < test_last_argv.len) test_last_argv[idx] = arg;
            }

            if (argv.len > 3 and std.mem.eql(u8, argv[3], "push")) {
                test_saw_push = true;
                for (argv) |arg| {
                    if (std.mem.eql(u8, arg, "-u")) test_saw_push_u = true;
                }
            }

            if (argv.len > 3 and std.mem.eql(u8, argv[3], "rev-parse")) {
                const out = try alloc.dupe(u8, "/tmp/repo\n");
                const err = try alloc.alloc(u8, 0);
                return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .Exited = 0 }, .allocator = alloc };
            }

            if (argv.len > 3 and std.mem.eql(u8, argv[3], "show-ref")) {
                const out = try alloc.alloc(u8, 0);
                return runner.RunResult{ .stdout = out, .stderr = out, .term = .{ .Exited = 0 }, .allocator = alloc };
            }

            if (argv.len > 3 and std.mem.eql(u8, argv[3], "status")) {
                const out = try alloc.dupe(u8, " M index.html\n");
                const err = try alloc.alloc(u8, 0);
                return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .Exited = 0 }, .allocator = alloc };
            }

            const out = try alloc.alloc(u8, 0);
            return runner.RunResult{ .stdout = out, .stderr = out, .term = .{ .Exited = 0 }, .allocator = alloc };
        }
    }.run };

    runner.setTestRunner(fake);
    defer runner.setTestRunner(null);

    try deploy(allocator, cfg, repo_root, .{ .remote = "origin", .branch = "gh-pages" }, std.io.null_writer, std.io.null_writer);
    try std.testing.expect(test_last_len > 0);
    try std.testing.expect(test_saw_push);
    try std.testing.expect(!test_saw_push_u);
}

test "deploy pushes with -u when remote missing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("repo/site");
    try tmp.dir.writeFile(.{ .sub_path = "repo/site/index.html", .data = "ok" });

    const repo_root = try tmp.dir.realpathAlloc(allocator, "repo");
    defer allocator.free(repo_root);
    const site_dir = try std.fs.path.join(allocator, &.{ repo_root, "site" });
    defer allocator.free(site_dir);
    const work_dir = try std.fs.path.join(allocator, &.{ repo_root, ".docforge", "work" });
    defer allocator.free(work_dir);

    const cfg = config.Config{
        .site = .{ .username = "sam", .path = "docs", .output_dir = site_dir },
        .cache_dir = ".docforge/cache",
        .work_dir = work_dir,
        .tool_templates = null,
        .repos = &.{},
    };

    test_last_len = 0;
    test_saw_push = false;
    test_saw_push_u = false;

    const fake = runner.TestRunner{ .run = struct {
        fn run(alloc: types.Allocator, argv: []const []const u8, _: ?[]const u8, _: runner.RunOptions) anyerror!runner.RunResult {
            test_last_len = argv.len;
            for (argv, 0..) |arg, idx| {
                if (idx < test_last_argv.len) test_last_argv[idx] = arg;
            }

            if (argv.len > 3 and std.mem.eql(u8, argv[3], "push")) {
                test_saw_push = true;
                for (argv) |arg| {
                    if (std.mem.eql(u8, arg, "-u")) test_saw_push_u = true;
                }
            }

            if (argv.len > 3 and std.mem.eql(u8, argv[3], "rev-parse")) {
                const out = try alloc.dupe(u8, "/tmp/repo\n");
                const err = try alloc.alloc(u8, 0);
                return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .Exited = 0 }, .allocator = alloc };
            }

            if (argv.len > 3 and std.mem.eql(u8, argv[3], "show-ref")) {
                const out = try alloc.alloc(u8, 0);
                return runner.RunResult{ .stdout = out, .stderr = out, .term = .{ .Exited = 1 }, .allocator = alloc };
            }

            if (argv.len > 3 and std.mem.eql(u8, argv[3], "status")) {
                const out = try alloc.dupe(u8, " M index.html\n");
                const err = try alloc.alloc(u8, 0);
                return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .Exited = 0 }, .allocator = alloc };
            }

            const out = try alloc.alloc(u8, 0);
            return runner.RunResult{ .stdout = out, .stderr = out, .term = .{ .Exited = 0 }, .allocator = alloc };
        }
    }.run };

    runner.setTestRunner(fake);
    defer runner.setTestRunner(null);

    try deploy(allocator, cfg, repo_root, .{ .remote = "origin", .branch = "gh-pages" }, std.io.null_writer, std.io.null_writer);
    try std.testing.expect(test_last_len > 0);
    try std.testing.expect(test_saw_push);
    try std.testing.expect(test_saw_push_u);
}

test "deploy errors when output dir missing" {
    const cfg = config.Config{
        .site = .{ .username = "sam", .path = "docs", .output_dir = "does-not-exist" },
        .cache_dir = ".docforge/cache",
        .work_dir = ".docforge/work",
        .tool_templates = null,
        .repos = &.{},
    };

    try std.testing.expectError(error.OutputDirMissing, deploy(std.testing.allocator, cfg, ".", .{}, std.io.null_writer, std.io.null_writer));
}

test "deploy skips push when no changes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("repo/site");
    try tmp.dir.writeFile(.{ .sub_path = "repo/site/index.html", .data = "ok" });

    const repo_root = try tmp.dir.realpathAlloc(allocator, "repo");
    defer allocator.free(repo_root);
    const site_dir = try std.fs.path.join(allocator, &.{ repo_root, "site" });
    defer allocator.free(site_dir);
    const work_dir = try std.fs.path.join(allocator, &.{ repo_root, ".docforge", "work" });
    defer allocator.free(work_dir);

    const cfg = config.Config{
        .site = .{ .username = "sam", .path = "docs", .output_dir = site_dir },
        .cache_dir = ".docforge/cache",
        .work_dir = work_dir,
        .tool_templates = null,
        .repos = &.{},
    };

    test_last_len = 0;
    test_saw_push = false;
    test_saw_push_u = false;

    const fake = runner.TestRunner{ .run = struct {
        fn run(alloc: types.Allocator, argv: []const []const u8, _: ?[]const u8, _: runner.RunOptions) anyerror!runner.RunResult {
            if (argv.len > 3 and std.mem.eql(u8, argv[3], "push")) {
                test_saw_push = true;
            }

            if (argv.len > 3 and std.mem.eql(u8, argv[3], "rev-parse")) {
                const out = try alloc.dupe(u8, "/tmp/repo\n");
                const err = try alloc.alloc(u8, 0);
                return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .Exited = 0 }, .allocator = alloc };
            }

            if (argv.len > 3 and std.mem.eql(u8, argv[3], "show-ref")) {
                const out = try alloc.alloc(u8, 0);
                return runner.RunResult{ .stdout = out, .stderr = out, .term = .{ .Exited = 0 }, .allocator = alloc };
            }

            if (argv.len > 3 and std.mem.eql(u8, argv[3], "status")) {
                const out = try alloc.alloc(u8, 0);
                const err = try alloc.alloc(u8, 0);
                return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .Exited = 0 }, .allocator = alloc };
            }

            const out = try alloc.alloc(u8, 0);
            return runner.RunResult{ .stdout = out, .stderr = out, .term = .{ .Exited = 0 }, .allocator = alloc };
        }
    }.run };

    runner.setTestRunner(fake);
    defer runner.setTestRunner(null);

    try deploy(allocator, cfg, repo_root, .{ .remote = "origin", .branch = "gh-pages" }, std.io.null_writer, std.io.null_writer);
    try std.testing.expect(!test_saw_push);
}

test "deploy preserves history when requested" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("repo/site");
    try tmp.dir.writeFile(.{ .sub_path = "repo/site/index.html", .data = "ok" });

    const repo_root = try tmp.dir.realpathAlloc(allocator, "repo");
    defer allocator.free(repo_root);
    const site_dir = try std.fs.path.join(allocator, &.{ repo_root, "site" });
    defer allocator.free(site_dir);
    const work_dir = try std.fs.path.join(allocator, &.{ repo_root, ".docforge", "work" });
    defer allocator.free(work_dir);

    const cfg = config.Config{
        .site = .{ .username = "sam", .path = "docs", .output_dir = site_dir },
        .cache_dir = ".docforge/cache",
        .work_dir = work_dir,
        .tool_templates = null,
        .repos = &.{},
    };

    test_saw_rm = false;
    test_saw_clean = false;

    const fake = runner.TestRunner{ .run = struct {
        fn run(alloc: types.Allocator, argv: []const []const u8, _: ?[]const u8, _: runner.RunOptions) anyerror!runner.RunResult {
            if (argv.len > 3 and std.mem.eql(u8, argv[3], "rm")) test_saw_rm = true;
            if (argv.len > 3 and std.mem.eql(u8, argv[3], "clean")) test_saw_clean = true;

            if (argv.len > 3 and std.mem.eql(u8, argv[3], "rev-parse")) {
                const out = try alloc.dupe(u8, "/tmp/repo\n");
                const err = try alloc.alloc(u8, 0);
                return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .Exited = 0 }, .allocator = alloc };
            }
            if (argv.len > 3 and std.mem.eql(u8, argv[3], "show-ref")) {
                const out = try alloc.alloc(u8, 0);
                return runner.RunResult{ .stdout = out, .stderr = out, .term = .{ .Exited = 0 }, .allocator = alloc };
            }
            if (argv.len > 3 and std.mem.eql(u8, argv[3], "status")) {
                const out = try alloc.dupe(u8, " M index.html\n");
                const err = try alloc.alloc(u8, 0);
                return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .Exited = 0 }, .allocator = alloc };
            }
            const out = try alloc.alloc(u8, 0);
            return runner.RunResult{ .stdout = out, .stderr = out, .term = .{ .Exited = 0 }, .allocator = alloc };
        }
    }.run };

    runner.setTestRunner(fake);
    defer runner.setTestRunner(null);

    try deploy(allocator, cfg, repo_root, .{ .remote = "origin", .branch = "gh-pages", .preserve_history = true }, std.io.null_writer, std.io.null_writer);
    try std.testing.expect(!test_saw_rm);
    try std.testing.expect(!test_saw_clean);
}

var test_last_argv: [16][]const u8 = undefined;
var test_last_len: usize = 0;
var test_saw_push: bool = false;
var test_saw_push_u: bool = false;
var test_saw_rm: bool = false;
var test_saw_clean: bool = false;
