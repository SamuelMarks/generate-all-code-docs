//! Top-level CLI orchestration for `init`, `discover`, `run`, `deploy`, `clean`, `list`, and `help` modes.

const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");
const args = @import("args.zig");
const source = @import("source.zig");
const fsutils = @import("fsutils.zig");
const paths = @import("paths.zig");
const runner = @import("runner.zig");
const git = @import("git.zig");
const archive = @import("archive.zig");
const doc_tool = @import("doc_tool.zig");
const manifest = @import("manifest.zig");
const discover = @import("discover.zig");
const index = @import("index.zig");
const deploy = @import("deploy.zig");
const inject = @import("inject.zig");

/// Execute the CLI workflow selected by `parsed.mode`.
///
/// @param allocator Backing allocator for all operations.
/// @param parsed Parsed command-line arguments.
/// @param stdout Concrete `*std.Io.Writer` for standard output.
/// @param stderr Concrete `*std.Io.Writer` for standard error.
pub fn run(
    allocator: types.Allocator,
    parsed: args.Args,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) types.GenerateAllCodeDocsError!void {
    switch (parsed.mode) {
        .help => try args.printUsage(stdout),
        .init => try runInit(allocator, parsed, stdout),
        .discover => try runDiscover(allocator, parsed, stdout),
        .run => try runGenerate(allocator, parsed, stdout, stderr),
        .deploy => try runDeploy(allocator, parsed, stdout, stderr),
        .clean => try runClean(allocator, parsed, stdout),
        .list => try runList(allocator, parsed, stdout),
    }
}

/// Initialize a starter `generate-all-code-docs.json` configuration and `<output_dir>/.nojekyll` file.
///
/// @param allocator Allocator for path joins.
/// @param parsed Parsed command-line arguments.
/// @param stdout Concrete `*std.Io.Writer` for status output.
fn runInit(
    allocator: types.Allocator,
    parsed: args.Args,
    stdout: *std.Io.Writer,
) types.GenerateAllCodeDocsError!void {
    try config.writeTemplate(parsed.config_path, parsed.init_username, parsed.init_path, parsed.init_output_dir);
    try fsutils.ensureDir(parsed.init_output_dir);
    const nojekyll_path = try std.Io.Dir.path.join(allocator, &.{ parsed.init_output_dir, ".nojekyll" });
    defer allocator.free(nojekyll_path);
    try fsutils.writeFile(nojekyll_path, "");
    try types.writeLogEvent(
        stdout,
        parsed.json,
        .{ .init = .{ .config = parsed.config_path, .output_dir = parsed.init_output_dir } },
    );
}

/// Scan `parsed.discover_root` for Git repositories and write a populated `generate-all-code-docs.json` file.
///
/// @param allocator Backing allocator for discovery and config serialization.
/// @param parsed Parsed command-line arguments.
/// @param stdout Concrete `*std.Io.Writer` for status output.
fn runDiscover(
    allocator: types.Allocator,
    parsed: args.Args,
    stdout: *std.Io.Writer,
) types.GenerateAllCodeDocsError!void {
    const io = fsutils.defaultIo();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const work = arena.allocator();

    const hits = try discover.discover(work, .{
        .root = parsed.discover_root,
        .max_depth = parsed.discover_depth,
        .infer_tool = parsed.discover_infer_tool,
    });

    std.sort.block(discover.RepoHit, hits, {}, repoHitLessThan);

    var repos = std.ArrayList(config.Repo).empty;
    defer repos.deinit(work);

    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", work);

    for (hits) |hit| {
        const abs_path = try std.Io.Dir.cwd().realPathFileAlloc(io, hit.path, work);
        const src_raw = if (parsed.discover_absolute)
            abs_path
        else
            try std.Io.Dir.path.relative(work, "", null, cwd, abs_path);
        const src_norm = try paths.normalizeSubpath(work, src_raw);
        const subpath = try outputSubpathFor(work, parsed.discover_root, hit.path, hit.name);

        try repos.append(work, .{
            .name = hit.name,
            .source = if (src_norm.len == 0) "." else src_norm,
            .doc_tool = hit.doc_tool,
            .output_subpath = subpath,
        });
    }

    const cfg = config.Config{
        .site = .{
            .username = parsed.init_username,
            .path = parsed.init_path,
            .output_dir = parsed.init_output_dir,
        },
        .repos = repos.items,
    };

    try config.write(parsed.config_path, cfg);
    try fsutils.ensureDir(parsed.init_output_dir);
    const nojekyll_path = try std.Io.Dir.path.join(work, &.{ parsed.init_output_dir, ".nojekyll" });
    try fsutils.writeFile(nojekyll_path, "");

    try types.writeLogEvent(
        stdout,
        parsed.json,
        .{ .discover = .{ .count = repos.items.len, .config = parsed.config_path } },
    );
}

/// Remove `output_dir`, `cache_dir`, and `work_dir` configured in `generate-all-code-docs.json`.
///
/// @param allocator Backing allocator for loading config.
/// @param parsed Parsed command-line arguments.
/// @param stdout Concrete `*std.Io.Writer` for status output.
fn runClean(
    allocator: types.Allocator,
    parsed: args.Args,
    stdout: *std.Io.Writer,
) types.GenerateAllCodeDocsError!void {
    const io = fsutils.defaultIo();
    var parsed_cfg = try config.load(allocator, parsed.config_path);
    defer parsed_cfg.deinit();
    const cfg = parsed_cfg.value;

    const dirs = [_][]const u8{ cfg.site.output_dir, cfg.cache_dir, cfg.work_dir };
    for (dirs) |dir| {
        if (!fsutils.dirExists(dir)) continue;
        if (parsed.dry_run) {
            try types.writeLogEvent(
                stdout,
                parsed.json,
                .{ .clean = .{ .path = dir, .action = "would-remove" } },
            );
            continue;
        }
        try std.Io.Dir.cwd().deleteTree(io, dir);
        try types.writeLogEvent(
            stdout,
            parsed.json,
            .{ .clean = .{ .path = dir, .action = "removed" } },
        );
    }
}

/// List configured repositories along with their detected/configured tool and cached commit/ref status.
///
/// @param allocator Backing allocator for loading config and manifests.
/// @param parsed Parsed command-line arguments.
/// @param stdout Concrete `*std.Io.Writer` for table or JSON output.
fn runList(
    allocator: types.Allocator,
    parsed: args.Args,
    stdout: *std.Io.Writer,
) types.GenerateAllCodeDocsError!void {
    var parsed_cfg = try config.load(allocator, parsed.config_path);
    defer parsed_cfg.deinit();
    const cfg = parsed_cfg.value;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const work = arena.allocator();

    const Row = struct {
        /// Repository display name.
        name: []const u8,
        /// Tool label.
        tool: []const u8,
        /// Commit or ref label.
        commit: []const u8,
    };
    var rows = std.ArrayList(Row).empty;
    defer rows.deinit(work);

    var max_name: usize = "Name".len;
    var max_tool: usize = "Tool".len;

    for (cfg.repos) |repo| {
        const name = repo.name orelse try paths.baseNameFromSource(work, repo.source);
        const key_seed = try std.fmt.allocPrint(work, "{s}|{s}", .{ name, repo.source });
        const repo_key = try paths.cacheKey(work, key_seed);
        const mf_path = try manifest.manifestPath(work, cfg.cache_dir, repo_key);
        const loaded_opt = try manifest.load(work, mf_path);
        defer if (loaded_opt) |*loaded| loaded.deinit();

        var tool_label: []const u8 = "auto";
        if (repo.doc_tool) |t| {
            tool_label = @tagName(t);
        } else if (loaded_opt) |loaded| {
            tool_label = @tagName(loaded.value.doc_tool);
        } else {
            const parsed_source = source.parse(repo.source);
            if (parsed_source.kind == .path and fsutils.dirExists(repo.source)) {
                if (doc_tool.infer(work, repo.source)) |inferred| {
                    tool_label = try std.fmt.allocPrint(work, "{s} (inferred)", .{@tagName(inferred)});
                } else |_| {}
            }
        }

        var commit_label: []const u8 = "-";
        if (loaded_opt) |loaded| {
            if (loaded.value.commit_short) |commit| {
                commit_label = commit;
            } else if (loaded.value.ref_value) |rv| {
                commit_label = rv;
            }
        } else if (repo.ref) |ref| {
            commit_label = try std.fmt.allocPrint(work, "{s}:{s}", .{ @tagName(ref.kind), ref.value });
        }

        const row = Row{
            .name = try work.dupe(u8, name),
            .tool = try work.dupe(u8, tool_label),
            .commit = try work.dupe(u8, commit_label),
        };
        if (row.name.len > max_name) max_name = row.name.len;
        if (row.tool.len > max_tool) max_tool = row.tool.len;
        try rows.append(work, row);
    }

    if (parsed.json) {
        for (rows.items) |row| {
            try types.writeLogEvent(
                stdout,
                true,
                .{ .list = .{ .name = row.name, .tool = row.tool, .commit = row.commit } },
            );
        }
        return;
    }

    try writePadded(stdout, "Name", max_name);
    try stdout.writeAll("  ");
    try writePadded(stdout, "Tool", max_tool);
    try stdout.writeAll("  Commit\x0a");

    for (rows.items) |row| {
        try writePadded(stdout, row.name, max_name);
        try stdout.writeAll("  ");
        try writePadded(stdout, row.tool, max_tool);
        try stdout.writeAll("  ");
        try stdout.writeAll(row.commit);
        try stdout.writeAll("\x0a");
    }
}

/// Load configuration and delegate deployment to `deploy.deploy`.
///
/// @param allocator Backing allocator for config loading and deployment.
/// @param parsed Parsed command-line arguments.
/// @param stdout Concrete `*std.Io.Writer` for status output.
/// @param stderr Concrete `*std.Io.Writer` for diagnostic error output.
fn runDeploy(
    allocator: types.Allocator,
    parsed: args.Args,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) types.GenerateAllCodeDocsError!void {
    const io = fsutils.defaultIo();
    var parsed_cfg = try config.load(allocator, parsed.config_path);
    defer parsed_cfg.deinit();

    const options = deploy.DeployOptions{
        .remote = parsed.deploy_remote,
        .branch = parsed.deploy_branch,
        .message = parsed.deploy_message,
        .dry_run = parsed.dry_run,
        .verbose = parsed.verbose,
        .json = parsed.json,
        .insecure = parsed.insecure,
        .preserve_history = parsed.deploy_preserve_history,
        .log_file = if (parsed.verbose) std.Io.File.stderr() else null,
    };

    try deploy.deploy(allocator, parsed_cfg.value, options, stdout, stderr);
    _ = io;
}

/// Generate documentation for all configured repositories, write the global index, and inject the index FAB.
///
/// @param allocator Backing allocator for build orchestration.
/// @param parsed Parsed command-line arguments.
/// @param stdout Concrete `*std.Io.Writer` for build outcomes.
/// @param stderr Concrete `*std.Io.Writer` for error diagnostics.
fn runGenerate(
    allocator: types.Allocator,
    parsed: args.Args,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) types.GenerateAllCodeDocsError!void {
    var parsed_cfg = try config.load(allocator, parsed.config_path);
    defer parsed_cfg.deinit();
    const cfg = parsed_cfg.value;

    if (!parsed.dry_run) {
        try fsutils.ensureDir(cfg.cache_dir);
        try fsutils.ensureDir(cfg.work_dir);
        try fsutils.ensureDir(cfg.site.output_dir);
        const manifest_dir = try manifest.manifestDir(allocator, cfg.cache_dir);
        defer allocator.free(manifest_dir);
        try fsutils.ensureDir(manifest_dir);
        try pruneCaches(allocator, cfg);
    }

    const site_root = try paths.outputPath(allocator, cfg.site.output_dir, cfg.site.path, "");
    defer allocator.free(site_root);
    if (!parsed.dry_run) {
        try fsutils.ensureDir(site_root);
        const nojekyll_path = try std.Io.Dir.path.join(allocator, &.{ cfg.site.output_dir, ".nojekyll" });
        defer allocator.free(nojekyll_path);
        try fsutils.writeFile(nojekyll_path, "");
    }

    var index_arena = std.heap.ArenaAllocator.init(allocator);
    defer index_arena.deinit();
    var index_entries = std.ArrayList(index.RepoEntry).empty;
    defer index_entries.deinit(index_arena.allocator());

    var log_mutex = std.Io.Mutex.init;
    const run_options = runner.RunOptions{
        .verbose = parsed.verbose,
        .log_file = if (parsed.verbose) std.Io.File.stderr() else null,
        .json = parsed.json,
        .insecure = parsed.insecure,
        .log_mutex = &log_mutex,
    };

    var results = try allocator.alloc(RepoTaskResult, cfg.repos.len);
    defer {
        for (results) |*res| res.deinit();
        allocator.free(results);
    }
    for (results) |*res| {
        res.* = .{};
    }

    var next_index = std.atomic.Value(usize).init(0);
    const cpu_count = std.Thread.getCpuCount() catch 1;
    const worker_count = if (cfg.repos.len == 0) 0 else @min(cfg.repos.len, @max(@as(usize, 1), cpu_count));

    if (worker_count <= 1) {
        for (cfg.repos, 0..) |repo, idx| {
            var repo_arena = std.heap.ArenaAllocator.init(allocator);
            const outcome = processRepo(repo_arena.allocator(), cfg, repo, parsed, run_options) catch |err| {
                repo_arena.deinit();
                results[idx] = .{ .err = err };
                continue;
            };
            results[idx] = .{ .arena = repo_arena, .outcome = outcome };
        }
    } else {
        const threads = try allocator.alloc(std.Thread, worker_count);
        defer allocator.free(threads);

        var ctx = WorkerContext{
            .backing_allocator = allocator,
            .cfg = cfg,
            .parsed = parsed,
            .run_options = run_options,
            .next_index = &next_index,
            .results = results,
        };

        for (threads, 0..) |*thread, idx| {
            _ = idx;
            thread.* = try std.Thread.spawn(.{}, workerMain, .{&ctx});
        }
        for (threads) |thread| {
            thread.join();
        }
    }

    var first_err: ?types.GenerateAllCodeDocsError = null;
    for (cfg.repos, 0..) |repo, idx| {
        const res = results[idx];
        if (res.err) |err| {
            if (first_err == null) first_err = err;
            const repo_name = repo.name orelse repo.source;
            try stderr.print("error [{s}]: {s}\x0a", .{ repo_name, @errorName(err) });
            try types.writeLogEvent(
                stdout,
                parsed.json,
                .{ .repo_error = .{
                    .name = repo_name,
                    .source = repo.source,
                    .error_name = @errorName(err),
                } },
            );
            continue;
        }
        const outcome = res.outcome.?;
        try logOutcome(stdout, parsed.json, outcome);
        if (!parsed.dry_run) {
            const copy = try index.RepoEntry.init(index_arena.allocator(), outcome.entry);
            try index_entries.append(index_arena.allocator(), copy);
        }
    }

    if (first_err) |err| return err;

    if (!parsed.dry_run) {
        try index.writeIndex(index_arena.allocator(), site_root, cfg.site, index_entries.items, cfg.index_template);
        _ = try inject.injectIndexFab(index_arena.allocator(), site_root);
    }
}

/// Process a single configured repository (materializing, checking manifest, running hooks and doc tool).
///
/// @param allocator Arena allocator scoped to this repository task.
/// @param cfg Top-level configuration.
/// @param repo Repository entry to build.
/// @param parsed Parsed CLI arguments.
/// @param options Runner execution options.
/// @return `RepoOutcome` summarizing the build status and index entry.
fn processRepo(
    allocator: types.Allocator,
    cfg: config.Config,
    repo: config.Repo,
    parsed: args.Args,
    options: runner.RunOptions,
) types.GenerateAllCodeDocsError!RepoOutcome {
    const repo_name = repo.name orelse try paths.baseNameFromSource(allocator, repo.source);
    const output_subpath = repo.output_subpath orelse repo_name;
    const output_dir = try paths.outputPath(allocator, cfg.site.output_dir, cfg.site.path, output_subpath);
    const key_seed = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ repo_name, repo.source });
    const repo_key = try paths.cacheKey(allocator, key_seed);
    const work_path = try std.Io.Dir.path.join(allocator, &.{ cfg.work_dir, repo_key });

    if (parsed.dry_run) {
        return RepoOutcome{
            .status = .dry_run,
            .repo_name = repo_name,
            .output_dir = output_dir,
            .tool = repo.doc_tool,
            .tool_inferred = false,
            .entry = .{
                .name = repo_name,
                .output_subpath = output_subpath,
                .source = repo.source,
                .doc_tool = repo.doc_tool orelse .mkdocs,
            },
        };
    }

    const materialized = try materializeRepo(allocator, cfg, repo, repo_key, work_path, options);
    const repo_root = try applyFilter(allocator, cfg, repo, repo_key, materialized.path);
    const tool = if (repo.doc_tool) |explicit| explicit else try doc_tool.infer(allocator, repo_root);
    const resolved_doc_path = try doc_tool.resolveDocPath(allocator, repo_root, tool, repo.doc_path);
    const build_hash = computeBuildHash(repo, cfg.tool_templates, tool, resolved_doc_path);

    const manifest_value = manifest.RepoManifest{
        .source = repo.source,
        .output_subpath = output_subpath,
        .doc_tool = tool,
        .doc_path = resolved_doc_path,
        .ref_kind = materialized.ref_kind,
        .ref_value = materialized.ref_value,
        .commit_short = materialized.commit_short,
        .build_hash = build_hash,
    };

    const mf_path = try manifest.manifestPath(allocator, cfg.cache_dir, repo_key);
    if (parsed.incremental and fsutils.dirExists(output_dir)) {
        if (try manifest.load(allocator, mf_path)) |loaded| {
            defer loaded.deinit();
            if (manifest.equals(loaded.value, manifest_value)) {
                return RepoOutcome{
                    .status = .skipped,
                    .repo_name = repo_name,
                    .output_dir = output_dir,
                    .tool = tool,
                    .tool_inferred = repo.doc_tool == null,
                    .source_path = repo_root,
                    .ref_value = materialized.ref_value,
                    .ref_kind = materialized.ref_kind,
                    .commit_short = materialized.commit_short,
                    .entry = .{
                        .name = repo_name,
                        .output_subpath = output_subpath,
                        .source = repo.source,
                        .doc_tool = tool,
                        .ref_kind = materialized.ref_kind,
                        .ref_value = materialized.ref_value,
                        .commit_short = materialized.commit_short,
                    },
                };
            }
        }
    }

    try runHooks(allocator, repo.pre_build, repo_root, options);

    try doc_tool.generate(allocator, .{
        .repo_root = repo_root,
        .output_dir = output_dir,
        .tool = tool,
        .doc_path = resolved_doc_path,
        .repo_name = repo_name,
        .source = repo.source,
        .ref = materialized.ref_value,
        .ref_kind = materialized.ref_kind,
        .commit_short = materialized.commit_short,
        .templates = cfg.tool_templates,
        .repo_argv = repo.argv,
        .run_options = options,
    });

    try runHooks(allocator, repo.post_build, repo_root, options);

    try manifest.save(mf_path, manifest_value);

    return RepoOutcome{
        .status = .built,
        .repo_name = repo_name,
        .output_dir = output_dir,
        .tool = tool,
        .tool_inferred = repo.doc_tool == null,
        .source_path = repo_root,
        .ref_value = materialized.ref_value,
        .ref_kind = materialized.ref_kind,
        .commit_short = materialized.commit_short,
        .entry = .{
            .name = repo_name,
            .output_subpath = output_subpath,
            .source = repo.source,
            .doc_tool = tool,
            .ref_kind = materialized.ref_kind,
            .ref_value = materialized.ref_value,
            .commit_short = materialized.commit_short,
        },
    };
}

/// Build status for a repository.
const RepoStatus = enum {
    /// Dry-run only; no files modified.
    dry_run,
    /// Skipped because output and manifest matched.
    skipped,
    /// Documentation built and written to `output_dir`.
    built,
};

/// Outcome of processing a single repository.
const RepoOutcome = struct {
    /// Build status (`dry_run`, `skipped`, or `built`).
    status: RepoStatus,
    /// Repository display name.
    repo_name: []const u8,
    /// Target output directory path.
    output_dir: []const u8,
    /// Documentation tool used or configured.
    tool: ?types.DocTool,
    /// Whether the tool was automatically inferred.
    tool_inferred: bool,
    /// Materialized source path on disk, if materialized.
    source_path: ?[]const u8 = null,
    /// Checked-out git reference value, if any.
    ref_value: ?[]const u8 = null,
    /// Checked-out git reference kind, if any.
    ref_kind: ?types.RefKind = null,
    /// Short git commit hash, if any.
    commit_short: ?[]const u8 = null,
    /// Global index entry for the repository.
    entry: index.RepoEntry,
};

/// Result slot for a single repository task in sequential or multi-threaded execution.
const RepoTaskResult = struct {
    /// Optional arena owning all strings in `outcome`.
    arena: ?std.heap.ArenaAllocator = null,
    /// Populated outcome when processing succeeded.
    outcome: ?RepoOutcome = null,
    /// Strongly-typed error when processing failed.
    err: ?types.GenerateAllCodeDocsError = null,

    /// Release the per-repository arena allocator if initialized.
    ///
    /// @param self Pointer to the `RepoTaskResult` to deinitialize.
    pub fn deinit(self: *RepoTaskResult) void {
        if (self.arena) |*arena| {
            arena.deinit();
        }
    }
};

/// Shared context passed to parallel worker threads during `runGenerate`.
const WorkerContext = struct {
    /// Thread-safe backing allocator used to initialize per-task arenas.
    backing_allocator: types.Allocator,
    /// Top-level configuration.
    cfg: config.Config,
    /// Parsed CLI arguments.
    parsed: args.Args,
    /// Runner execution options.
    run_options: runner.RunOptions,
    /// Atomic counter for claiming the next repository index.
    next_index: *std.atomic.Value(usize),
    /// Pre-allocated result slice indexed by repository position.
    results: []RepoTaskResult,
};

/// Entry point for parallel worker threads processing repositories from `ctx.next_index`.
///
/// @param ctx Shared `WorkerContext` pointer.
fn workerMain(ctx: *WorkerContext) void {
    while (true) {
        const idx = ctx.next_index.fetchAdd(1, .monotonic);
        if (idx >= ctx.cfg.repos.len) break;

        var arena = std.heap.ArenaAllocator.init(ctx.backing_allocator);
        const allocator = arena.allocator();
        const outcome = processRepo(allocator, ctx.cfg, ctx.cfg.repos[idx], ctx.parsed, ctx.run_options) catch |err| {
            arena.deinit();
            ctx.results[idx] = .{ .err = err };
            continue;
        };

        ctx.results[idx] = .{ .arena = arena, .outcome = outcome };
    }
}

/// Write a `RepoOutcome` to `stdout` in JSON or human-readable format.
///
/// @param stdout Concrete `*std.Io.Writer` stream.
/// @param json Whether to emit a structured JSON log line.
/// @param outcome Completed `RepoOutcome` to log.
fn logOutcome(stdout: *std.Io.Writer, json: bool, outcome: RepoOutcome) std.Io.Writer.Error!void {
    const tool_str = if (outcome.tool) |t| @tagName(t) else null;
    const ref_kind_str = if (outcome.ref_kind) |k| @tagName(k) else null;
    const event = types.LogEvent{ .repo = .{
        .name = outcome.repo_name,
        .output = outcome.output_dir,
        .status = @tagName(outcome.status),
        .tool = tool_str,
        .tool_inferred = outcome.tool_inferred,
        .source = outcome.source_path,
        .ref = outcome.ref_value,
        .ref_kind = ref_kind_str,
        .commit = outcome.commit_short,
    } };

    try types.writeLogEvent(stdout, json, event);
}

/// Materialized repository location and resolved git metadata on disk.
const Materialized = struct {
    /// Filesystem path to the materialized repository root.
    path: []const u8,
    /// Resolved reference kind, if applicable.
    ref_kind: ?types.RefKind = null,
    /// Resolved reference value, if applicable.
    ref_value: ?[]const u8 = null,
    /// Short commit hash, if applicable.
    commit_short: ?[]const u8 = null,
};

/// Materialize a repository from a local path, Git remote, or archive URL into a local directory.
///
/// @param allocator Arena allocator for paths and git queries.
/// @param cfg Top-level configuration.
/// @param repo Repository entry.
/// @param repo_key Cache key for the repository.
/// @param work_path Worktree/extraction directory path.
/// @param options Runner execution options.
/// @return `Materialized` path and reference metadata.
fn materializeRepo(
    allocator: types.Allocator,
    cfg: config.Config,
    repo: config.Repo,
    repo_key: []const u8,
    work_path: []const u8,
    options: runner.RunOptions,
) types.GenerateAllCodeDocsError!Materialized {
    const parsed_source = source.parse(repo.source);
    return switch (parsed_source.kind) {
        .path => try materializePath(allocator, repo, work_path, options),
        .git_ssh, .git_https => try materializeGitRemote(allocator, cfg, repo, work_path, options),
        .archive_url => try materializeArchive(allocator, cfg, repo, repo_key, work_path, options),
    };
}

/// Materialize a local filesystem repository (creating a worktree if `repo.ref` is specified).
///
/// @param allocator Arena allocator.
/// @param repo Repository configuration.
/// @param work_path Worktree path if checking out a ref.
/// @param options Runner execution options.
/// @return `Materialized` path and inferred or configured git metadata.
fn materializePath(
    allocator: types.Allocator,
    repo: config.Repo,
    work_path: []const u8,
    options: runner.RunOptions,
) types.GenerateAllCodeDocsError!Materialized {
    const is_git = git.isGitRepo(repo.source);
    if (repo.ref) |ref| {
        if (!is_git) {
            return Materialized{ .path = repo.source, .ref_kind = ref.kind, .ref_value = ref.value };
        }
        try git.ensureWorktree(allocator, repo.source, work_path, ref.value, options);
        const info = try git.inferRef(allocator, work_path, options);
        return Materialized{
            .path = work_path,
            .ref_kind = ref.kind,
            .ref_value = ref.value,
            .commit_short = info.commit_short,
        };
    }

    if (is_git) {
        const info = try git.inferRef(allocator, repo.source, options);
        return Materialized{
            .path = repo.source,
            .ref_kind = info.kind,
            .ref_value = info.ref,
            .commit_short = info.commit_short,
        };
    }

    return Materialized{ .path = repo.source };
}

/// Materialize a remote Git repository via cached clone and detached worktree checkout.
///
/// @param allocator Arena allocator.
/// @param cfg Top-level configuration.
/// @param repo Repository configuration.
/// @param work_path Worktree destination path.
/// @param options Runner execution options.
/// @return `Materialized` worktree path and git reference metadata.
fn materializeGitRemote(
    allocator: types.Allocator,
    cfg: config.Config,
    repo: config.Repo,
    work_path: []const u8,
    options: runner.RunOptions,
) types.GenerateAllCodeDocsError!Materialized {
    const remote_key = try paths.cacheKey(allocator, repo.source);
    const cache_repo = try std.Io.Dir.path.join(allocator, &.{ cfg.cache_dir, remote_key });
    try git.ensureClone(allocator, repo.source, cache_repo, repo.shallow, options);

    if (repo.ref) |ref| {
        try git.ensureWorktree(allocator, cache_repo, work_path, ref.value, options);
        const info = try git.inferRef(allocator, work_path, options);
        return Materialized{
            .path = work_path,
            .ref_kind = ref.kind,
            .ref_value = ref.value,
            .commit_short = info.commit_short,
        };
    }

    const info = try git.inferRef(allocator, cache_repo, options);
    try git.ensureWorktree(allocator, cache_repo, work_path, info.ref, options);
    return Materialized{
        .path = work_path,
        .ref_kind = info.kind,
        .ref_value = info.ref,
        .commit_short = info.commit_short,
    };
}

/// Materialize an archive URL by downloading to cache, extracting to `work_path`, and resolving its root.
///
/// @param allocator Arena allocator.
/// @param cfg Top-level configuration.
/// @param repo Repository configuration.
/// @param repo_key Cache key for the repository.
/// @param work_path Extraction directory path.
/// @param options Runner execution options.
/// @return `Materialized` extracted root directory path.
fn materializeArchive(
    allocator: types.Allocator,
    cfg: config.Config,
    repo: config.Repo,
    repo_key: []const u8,
    work_path: []const u8,
    options: runner.RunOptions,
) types.GenerateAllCodeDocsError!Materialized {
    const kind = archive.detectKind(repo.source) orelse return error.UnsupportedArchive;
    const ext = kind.canonicalExt();
    const archive_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ repo_key, ext });
    const archive_path = try std.Io.Dir.path.join(allocator, &.{ cfg.cache_dir, archive_name });

    try archive.ensureDownload(allocator, repo.source, archive_path, options);
    try archive.extract(allocator, archive_path, work_path, kind, options);

    const root = try archive.resolveRoot(allocator, work_path);
    return Materialized{ .path = root };
}

/// Apply optional `include`/`exclude` glob filters by copying matching files into `<work_dir>/<repo_key>-filtered`.
///
/// @param allocator Arena allocator.
/// @param cfg Top-level configuration.
/// @param repo Repository configuration.
/// @param repo_key Repository cache key.
/// @param repo_root Unfiltered repository root directory.
/// @return Filtered directory path if globs are configured, or `repo_root` unchanged.
fn applyFilter(
    allocator: types.Allocator,
    cfg: config.Config,
    repo: config.Repo,
    repo_key: []const u8,
    repo_root: []const u8,
) types.GenerateAllCodeDocsError![]const u8 {
    if (repo.include == null and repo.exclude == null) return repo_root;
    const filtered_name = try std.fmt.allocPrint(allocator, "{s}-filtered", .{repo_key});
    const filtered_path = try std.Io.Dir.path.join(allocator, &.{ cfg.work_dir, filtered_name });
    try fsutils.ensureEmptyDir(filtered_path);
    try fsutils.copyDirFiltered(allocator, repo_root, filtered_path, .{
        .include = repo.include,
        .exclude = repo.exclude,
    });
    return filtered_path;
}

/// Prune unreferenced git clones and archive files from `cfg.cache_dir`.
///
/// @param allocator Backing allocator for temporary key lists.
/// @param cfg Top-level configuration.
fn pruneCaches(allocator: types.Allocator, cfg: config.Config) types.GenerateAllCodeDocsError!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const work = arena.allocator();

    var git_keys = std.ArrayList([]const u8).empty;
    defer git_keys.deinit(work);
    var archive_keys = std.ArrayList([]const u8).empty;
    defer archive_keys.deinit(work);

    for (cfg.repos) |repo| {
        const parsed_source = source.parse(repo.source);
        switch (parsed_source.kind) {
            .git_ssh, .git_https => {
                const key = try paths.cacheKey(work, repo.source);
                try git_keys.append(work, key);
            },
            .archive_url => {
                const repo_name = repo.name orelse try paths.baseNameFromSource(work, repo.source);
                const key_seed = try std.fmt.allocPrint(work, "{s}|{s}", .{ repo_name, repo.source });
                const key = try paths.cacheKey(work, key_seed);
                try archive_keys.append(work, key);
            },
            .path => {},
        }
    }

    try git.pruneCache(work, cfg.cache_dir, git_keys.items);
    try archive.pruneCache(work, cfg.cache_dir, archive_keys.items);
}

/// Compute the relative output subpath for a discovered repository under `discover_root`.
///
/// @param allocator Allocator for path strings.
/// @param discover_root Discovery root directory path.
/// @param repo_path Discovered repository path.
/// @param fallback_name Fallback basename if the discovered repository is at `discover_root`.
/// @return Normalized output subpath owned by caller.
fn outputSubpathFor(
    allocator: types.Allocator,
    discover_root: []const u8,
    repo_path: []const u8,
    fallback_name: []const u8,
) (std.mem.Allocator.Error || error{OutputPathCollision})![]const u8 {
    const rel = try std.Io.Dir.path.relative(allocator, "", null, discover_root, repo_path);
    defer allocator.free(rel);
    if (std.mem.eql(u8, rel, ".") or rel.len == 0) {
        return allocator.dupe(u8, fallback_name);
    }
    const normalized = try paths.normalizeSubpath(allocator, rel);
    if (normalized.len == 0) {
        allocator.free(normalized);
        return allocator.dupe(u8, fallback_name);
    }
    return normalized;
}

/// Execute an optional list of hook commands (`pre_build` or `post_build`) in `cwd`.
///
/// @param allocator Allocator for subprocess execution.
/// @param hooks Optional slice of command argument vectors.
/// @param cwd Working directory for the commands.
/// @param options Runner execution options.
fn runHooks(
    allocator: types.Allocator,
    hooks: ?types.CommandList,
    cwd: []const u8,
    options: runner.RunOptions,
) types.GenerateAllCodeDocsError!void {
    if (hooks == null) return;
    for (hooks.?) |cmd| {
        if (cmd.len == 0) return error.EmptyHookCommand;
        var result = try runner.runChecked(allocator, cmd, cwd, options);
        result.deinit();
    }
}

/// Compute a 64-bit Wyhash fingerprint of all build inputs affecting a repository's generated output.
///
/// @param repo Repository configuration.
/// @param templates Optional tool command templates.
/// @param tool Resolved `DocTool`.
/// @param resolved_doc_path Resolved tool documentation path.
/// @return 64-bit Wyhash digest.
fn computeBuildHash(
    repo: config.Repo,
    templates: ?types.ToolTemplates,
    tool: types.DocTool,
    resolved_doc_path: ?[]const u8,
) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hashString(&hasher, @tagName(tool));
    hashOptional(&hasher, resolved_doc_path);
    hashOptional(&hasher, repo.include);
    hashOptional(&hasher, repo.exclude);
    hashCommandOpt(&hasher, repo.argv);
    hashCommandListOpt(&hasher, repo.pre_build);
    hashCommandListOpt(&hasher, repo.post_build);

    if (templates) |tpls| {
        const tpl = switch (tool) {
            .mkdocs => tpls.mkdocs,
            .sphinx => tpls.sphinx,
            .doxygen => tpls.doxygen,
            .godoc => tpls.godoc,
            .cargo => tpls.cargo,
            .shell => null,
        };
        if (tpl) |item| {
            hashCommand(&hasher, item.argv);
        } else {
            hashString(&hasher, "no-template");
        }
    } else {
        hashString(&hasher, "no-templates");
    }

    return hasher.final();
}

/// Update `hasher` with a length-delimited string slice.
///
/// @param hasher Pointer to active `Wyhash` state.
/// @param value String slice to hash.
fn hashString(hasher: *std.hash.Wyhash, value: []const u8) void {
    hasher.update(value);
    hasher.update(&.{0});
}

/// Update `hasher` with an optional string slice.
///
/// @param hasher Pointer to active `Wyhash` state.
/// @param value Optional string slice to hash.
fn hashOptional(hasher: *std.hash.Wyhash, value: ?[]const u8) void {
    if (value) |v| {
        hashString(hasher, v);
    } else {
        hashString(hasher, "null");
    }
}

/// Update `hasher` with a command argument vector.
///
/// @param hasher Pointer to active `Wyhash` state.
/// @param cmd Command argument slice.
fn hashCommand(hasher: *std.hash.Wyhash, cmd: types.Command) void {
    for (cmd) |arg| {
        hashString(hasher, arg);
    }
    hashString(hasher, "cmd-end");
}

/// Update `hasher` with an optional command argument vector.
///
/// @param hasher Pointer to active `Wyhash` state.
/// @param cmd Optional command argument slice.
fn hashCommandOpt(hasher: *std.hash.Wyhash, cmd: ?types.Command) void {
    if (cmd) |c| {
        hashCommand(hasher, c);
    } else {
        hashString(hasher, "no-cmd");
    }
}

/// Update `hasher` with an optional list of command argument vectors.
///
/// @param hasher Pointer to active `Wyhash` state.
/// @param list Optional command list.
fn hashCommandListOpt(hasher: *std.hash.Wyhash, list: ?types.CommandList) void {
    if (list) |items| {
        for (items) |cmd| {
            hashCommand(hasher, cmd);
        }
        hashString(hasher, "list-end");
    } else {
        hashString(hasher, "no-list");
    }
}

/// Comparator for sorting `discover.RepoHit` entries lexicographically by path.
///
/// @param context Unused sort context (`void`).
/// @param a First `RepoHit`.
/// @param b Second `RepoHit`.
/// @return `true` if `a.path` sorts before `b.path`.
fn repoHitLessThan(context: void, a: discover.RepoHit, b: discover.RepoHit) bool {
    _ = context;
    return std.mem.lessThan(u8, a.path, b.path);
}

/// Write `value` padded with trailing spaces up to `width` bytes.
///
/// @param writer Target `*std.Io.Writer`.
/// @param value String to write.
/// @param width Minimum column width.
fn writePadded(writer: *std.Io.Writer, value: []const u8, width: usize) std.Io.Writer.Error!void {
    try writer.writeAll(value);
    if (value.len >= width) return;
    var remaining = width - value.len;
    while (remaining > 0) : (remaining -= 1) {
        try writer.writeAll(" ");
    }
}

test "run prints usage in help mode" {
    // covers: app.run
    var out_buf: [2048]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var err_writer = std.Io.Writer.fixed(&err_buf);

    const parsed = args.Args{ .mode = .help };
    try run(std.testing.allocator, parsed, &out_writer, &err_writer);

    const output = out_writer.buffered();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "generate-all-code-docs usage"));
}

test "runInit and runDiscover create config and .nojekyll" {
    // covers: app.runInit app.runDiscover app.outputSubpathFor app.repoHitLessThan
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);

    const init_cfg = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "init.json" });
    defer std.testing.allocator.free(init_cfg);
    const site_dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "site" });
    defer std.testing.allocator.free(site_dir);

    var out_buf: [2048]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var err_writer = std.Io.Writer.fixed(&err_buf);

    try run(std.testing.allocator, .{
        .mode = .init,
        .config_path = init_cfg,
        .init_username = "alice",
        .init_path = "docs",
        .init_output_dir = site_dir,
    }, &out_writer, &err_writer);
    try std.testing.expect(fsutils.fileExists(init_cfg));

    // Discover with two repos + root repo fallback
    try tmp.dir.createDirPath(std.testing.io, "scan/b_repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "scan/a_repo/.git");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scan/a_repo/mkdocs.yml", .data = "site_name: a\x0a" });

    const scan_root = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "scan" });
    defer std.testing.allocator.free(scan_root);
    const disc_cfg = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "disc.json" });
    defer std.testing.allocator.free(disc_cfg);

    var disc_writer = std.Io.Writer.fixed(&out_buf);
    try run(std.testing.allocator, .{
        .mode = .discover,
        .config_path = disc_cfg,
        .discover_root = scan_root,
        .discover_absolute = true,
        .init_output_dir = site_dir,
        .json = true,
    }, &disc_writer, &err_writer);
    try std.testing.expect(fsutils.fileExists(disc_cfg));
    try std.testing.expect(std.mem.containsAtLeast(u8, disc_writer.buffered(), 1, "\x22event\x22:\x22discover\x22"));

    // Test outputSubpathFor when repo_path == discover_root
    const sub_same = try outputSubpathFor(std.testing.allocator, scan_root, scan_root, "fallback");
    defer std.testing.allocator.free(sub_same);
    try std.testing.expectEqualStrings("fallback", sub_same);
}

test "runGenerate, runList, runClean, and runDeploy cover full lifecycle and multi-threaded workers" {
    // covers: app.runGenerate app.processRepo app.workerMain app.logOutcome app.materializeRepo app.materializePath app.materializeGitRemote app.materializeArchive app.applyFilter app.pruneCaches app.runHooks app.computeBuildHash app.hashString app.hashOptional app.hashCommand app.hashCommandOpt app.hashCommandListOpt app.runClean app.runList app.writePadded app.runDeploy app.deinit
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);

    try tmp.dir.createDirPath(std.testing.io, "repo_local");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo_local/mkdocs.yml", .data = "site_name: local\x0a" });
    try tmp.dir.createDirPath(std.testing.io, "repo_git/.git");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo_git/mkdocs.yml", .data = "site_name: git\x0a" });

    const repo_local = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "repo_local" });
    defer std.testing.allocator.free(repo_local);
    const repo_git = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "repo_git" });
    defer std.testing.allocator.free(repo_git);
    const site_dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "site" });
    defer std.testing.allocator.free(site_dir);
    const cache_dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "cache" });
    defer std.testing.allocator.free(cache_dir);
    const work_dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "work" });
    defer std.testing.allocator.free(work_dir);
    const cfg_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "generate-all-code-docs.json" });
    defer std.testing.allocator.free(cfg_path);

    const pre_cmd = [_][]const u8{ "echo", "pre" };
    const pre_list = [_]types.Command{pre_cmd[0..]};
    const shell_argv = [_][]const u8{ "echo", "{output_dir}" };

    var repos = [_]config.Repo{
        .{
            .name = "r_local",
            .source = repo_local,
            .ref = .{ .kind = .version, .value = "1.0" },
            .include = "*.yml",
            .pre_build = pre_list[0..],
        },
        .{
            .name = "r_git_ref",
            .source = repo_git,
            .ref = .{ .kind = .tag, .value = "v1.0" },
            .doc_tool = .shell,
            .argv = shell_argv[0..],
        },
        .{
            .name = "r_git_head",
            .source = repo_git,
        },
        .{
            .name = "r_remote",
            .source = "https://github.com/example/remote.git",
            .doc_tool = .mkdocs,
        },
        .{
            .name = "r_remote_ref",
            .source = "git@github.com:example/remote_ref.git",
            .ref = .{ .kind = .commit, .value = "deadbeef" },
            .doc_tool = .mkdocs,
        },
        .{
            .name = "r_archive",
            .source = "https://example.com/archive.zip",
            .doc_tool = .mkdocs,
        },
    };

    const cfg = config.Config{
        .site = .{ .username = "sam", .path = "docs", .output_dir = site_dir },
        .cache_dir = cache_dir,
        .work_dir = work_dir,
        .tool_templates = .{ .mkdocs = .{ .argv = &.{ "mkdocs", "build", "-d", "{output_dir}" } } },
        .repos = repos[0..],
    };
    try config.write(cfg_path, cfg);

    const fake = runner.TestRunner{ .run = struct {
        fn runFn(alloc: types.Allocator, argv: []const []const u8, _: ?[]const u8, _: runner.RunOptions) types.GenerateAllCodeDocsError!runner.RunResult {
            if (argv.len >= 4 and std.mem.eql(u8, argv[0], "git") and std.mem.eql(u8, argv[3], "describe")) {
                const out = try alloc.dupe(u8, "v1.0.0\x0a");
                const err = try alloc.alloc(u8, 0);
                return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .exited = 0 }, .allocator = alloc };
            }
            if (argv.len >= 4 and std.mem.eql(u8, argv[0], "git") and std.mem.eql(u8, argv[3], "rev-parse")) {
                const out = try alloc.dupe(u8, "abc1234\x0a");
                const err = try alloc.alloc(u8, 0);
                return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .exited = 0 }, .allocator = alloc };
            }
            if (argv.len >= 4 and std.mem.eql(u8, argv[0], "git") and std.mem.eql(u8, argv[3], "log")) {
                const out = try alloc.dupe(u8, "commit msg\x0a");
                const err = try alloc.alloc(u8, 0);
                return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .exited = 0 }, .allocator = alloc };
            }
            const out = try alloc.alloc(u8, 0);
            const err = try alloc.alloc(u8, 0);
            return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .exited = 0 }, .allocator = alloc };
        }
    }.runFn };

    runner.setTestRunner(fake);
    defer runner.setTestRunner(null);

    var out_buf: [8192]u8 = undefined;
    var err_buf: [2048]u8 = undefined;

    // 1. Dry-run generate
    var dry_writer = std.Io.Writer.fixed(&out_buf);
    var err_writer = std.Io.Writer.fixed(&err_buf);
    try run(std.testing.allocator, .{ .mode = .run, .config_path = cfg_path, .dry_run = true }, &dry_writer, &err_writer);
    try std.testing.expect(std.mem.containsAtLeast(u8, dry_writer.buffered(), 1, "DRY-RUN"));

    // 2. List before build (inferred and ref labels)
    var list_pre_writer = std.Io.Writer.fixed(&out_buf);
    try run(std.testing.allocator, .{ .mode = .list, .config_path = cfg_path }, &list_pre_writer, &err_writer);
    try std.testing.expect(std.mem.containsAtLeast(u8, list_pre_writer.buffered(), 1, "mkdocs (inferred)"));

    // 3. Full multi-repo generate
    var gen_writer = std.Io.Writer.fixed(&out_buf);
    try run(std.testing.allocator, .{ .mode = .run, .config_path = cfg_path }, &gen_writer, &err_writer);
    try std.testing.expect(std.mem.containsAtLeast(u8, gen_writer.buffered(), 1, "OK r_local"));

    // 4. Incremental generate (should SKIP all 6 repos)
    var skip_writer = std.Io.Writer.fixed(&out_buf);
    try run(std.testing.allocator, .{ .mode = .run, .config_path = cfg_path, .incremental = true }, &skip_writer, &err_writer);
    try std.testing.expect(std.mem.containsAtLeast(u8, skip_writer.buffered(), 1, "SKIP r_local"));

    // 5. List after build (text and JSON)
    var list_post_writer = std.Io.Writer.fixed(&out_buf);
    try run(std.testing.allocator, .{ .mode = .list, .config_path = cfg_path }, &list_post_writer, &err_writer);
    try std.testing.expect(std.mem.containsAtLeast(u8, list_post_writer.buffered(), 1, "abc1234"));

    var list_json_writer = std.Io.Writer.fixed(&out_buf);
    try run(std.testing.allocator, .{ .mode = .list, .config_path = cfg_path, .json = true }, &list_json_writer, &err_writer);
    try std.testing.expect(std.mem.containsAtLeast(u8, list_json_writer.buffered(), 1, "\x22event\x22:\x22list\x22"));

    // 6. Deploy dry-run via app.run
    var dep_writer = std.Io.Writer.fixed(&out_buf);
    try run(std.testing.allocator, .{ .mode = .deploy, .config_path = cfg_path, .dry_run = true }, &dep_writer, &err_writer);
    try std.testing.expect(std.mem.containsAtLeast(u8, dep_writer.buffered(), 1, "Deploying"));

    // 7. Clean dry-run and real clean
    var clean_dry_writer = std.Io.Writer.fixed(&out_buf);
    try run(std.testing.allocator, .{ .mode = .clean, .config_path = cfg_path, .dry_run = true }, &clean_dry_writer, &err_writer);
    try std.testing.expect(std.mem.containsAtLeast(u8, clean_dry_writer.buffered(), 1, "Would remove"));

    var clean_writer = std.Io.Writer.fixed(&out_buf);
    try run(std.testing.allocator, .{ .mode = .clean, .config_path = cfg_path }, &clean_writer, &err_writer);
    try std.testing.expect(std.mem.containsAtLeast(u8, clean_writer.buffered(), 1, "Removed"));
    try std.testing.expect(!fsutils.dirExists(site_dir));
}

test "runGenerate sequential single-repo and error reporting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);

    try tmp.dir.createDirPath(std.testing.io, "empty_repo");
    const empty_repo = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "empty_repo" });
    defer std.testing.allocator.free(empty_repo);
    const cfg_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "bad.json" });
    defer std.testing.allocator.free(cfg_path);
    const site_dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "site" });
    defer std.testing.allocator.free(site_dir);
    const cache_dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "cache" });
    defer std.testing.allocator.free(cache_dir);
    const work_dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "work" });
    defer std.testing.allocator.free(work_dir);

    var repos = [_]config.Repo{.{
        .name = "broken",
        .source = empty_repo,
    }};
    const cfg = config.Config{
        .site = .{ .username = "sam", .path = "docs", .output_dir = site_dir },
        .cache_dir = cache_dir,
        .work_dir = work_dir,
        .repos = repos[0..],
    };
    try config.write(cfg_path, cfg);

    var out_buf: [1024]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var err_writer = std.Io.Writer.fixed(&err_buf);

    try std.testing.expectError(error.ToolNotInferred, run(std.testing.allocator, .{ .mode = .run, .config_path = cfg_path }, &out_writer, &err_writer));
    try std.testing.expect(std.mem.containsAtLeast(u8, err_writer.buffered(), 1, "ToolNotInferred"));

    // Empty hook command error
    const empty_cmd = [_][]const u8{};
    const empty_hooks = [_]types.Command{empty_cmd[0..]};
    try std.testing.expectError(error.EmptyHookCommand, runHooks(std.testing.allocator, empty_hooks[0..], base, .{}));
}
