const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");
const args = @import("args.zig");
const source = @import("source.zig");
const fsutils = @import("fsutils.zig");
const paths = @import("paths.zig");
const doc_tool = @import("doc_tool.zig");
const git = @import("git.zig");
const archive = @import("archive.zig");
const runner = @import("runner.zig");
const manifest = @import("manifest.zig");
const discover = @import("discover.zig");
const index = @import("index.zig");
const inject = @import("inject.zig");
const deploy = @import("deploy.zig");

const LogOptions = struct {
    json: bool,
};

const RepoStatus = enum {
    dry_run,
    skipped,
    built,
};

const ProcessOutcome = struct {
    name: []const u8,
    output_dir: []const u8,
    tool: ?types.DocTool,
    tool_inferred: bool,
    status: RepoStatus,
    source_path: ?[]const u8 = null,
    ref_info: ?git.RefInfo = null,
    entry: ?index.RepoEntry = null,
};

const RepoTaskResult = struct {
    arena: ?std.heap.ArenaAllocator = null,
    outcome: ?ProcessOutcome = null,
    err: ?anyerror = null,
};

const WorkerContext = struct {
    cfg: config.Config,
    repos: []const config.Repo,
    start_index: usize,
    results: []RepoTaskResult,
    dry_run: bool,
    incremental: bool,
    options: runner.RunOptions,
};

const HookError = error{
    EmptyHookCommand,
};

/// Run the CLI with the parsed arguments.
pub fn run(allocator: types.Allocator, parsed: args.Args, stdout: anytype, stderr: anytype) !void {
    switch (parsed.mode) {
        .help => try args.printUsage(stdout),
        .init => try runInit(parsed, stdout),
        .discover => try runDiscover(allocator, parsed, stdout),
        .run => try runGenerate(allocator, parsed, stdout, stderr),
        .deploy => try runDeploy(allocator, parsed, stdout, stderr),
        .clean => try runClean(allocator, parsed, stdout),
        .list => try runList(allocator, parsed, stdout),
    }
}

fn runInit(parsed: args.Args, stdout: anytype) !void {
    const log = LogOptions{ .json = parsed.json };
    try config.writeTemplate(parsed.config_path, parsed.init_username, parsed.init_path, parsed.init_output_dir);
    try fsutils.ensureDir(parsed.init_output_dir);
    const nojekyll = try std.fs.path.join(std.heap.page_allocator, &.{ parsed.init_output_dir, ".nojekyll" });
    defer std.heap.page_allocator.free(nojekyll);
    if (!fsutils.fileExists(nojekyll)) {
        try fsutils.writeFile(nojekyll, "");
    }
    try logEvent(stdout, log, .{
        .event = "init",
        .config = parsed.config_path,
        .output_dir = parsed.init_output_dir,
    }, "Wrote {s}\n", .{parsed.config_path});
}

fn runDiscover(allocator: types.Allocator, parsed: args.Args, stdout: anytype) !void {
    const log = LogOptions{ .json = parsed.json };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const work = arena.allocator();

    const root_abs = try std.fs.cwd().realpathAlloc(work, parsed.discover_root);
    const config_dir_raw = std.fs.path.dirname(parsed.config_path) orelse ".";
    try fsutils.ensureDir(config_dir_raw);
    const config_dir = std.fs.cwd().realpathAlloc(work, config_dir_raw) catch try std.fs.cwd().realpathAlloc(work, ".");

    const hits = try discover.discover(work, root_abs, .{ .max_depth = parsed.discover_depth, .infer_tool = parsed.discover_infer_tool });
    std.sort.pdq(discover.RepoHit, hits, {}, repoLessThan);

    const repos = try work.alloc(config.Repo, hits.len);
    for (hits, 0..) |hit, idx| {
        const source_path = if (parsed.discover_absolute)
            hit.path
        else
            (std.fs.path.relative(work, config_dir, hit.path) catch hit.path);

        const output_subpath = try outputSubpath(work, root_abs, hit.path);

        repos[idx] = .{
            .name = hit.name,
            .source = source_path,
            .doc_tool = hit.doc_tool,
            .output_subpath = output_subpath,
        };
    }

    const cfg = config.Config{
        .site = .{
            .username = parsed.init_username,
            .path = parsed.init_path,
            .output_dir = parsed.init_output_dir,
        },
        .cache_dir = ".docforge/cache",
        .work_dir = ".docforge/work",
        .repos = repos,
    };

    try config.write(parsed.config_path, cfg);
    try logEvent(stdout, log, .{
        .event = "discover",
        .count = hits.len,
        .config = parsed.config_path,
    }, "Discovered {d} repos -> {s}\n", .{ hits.len, parsed.config_path });
}

fn repoLessThan(_: void, a: discover.RepoHit, b: discover.RepoHit) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

fn outputSubpath(allocator: types.Allocator, root_abs: []const u8, repo_path: []const u8) ![]const u8 {
    const rel = std.fs.path.relative(allocator, root_abs, repo_path) catch {
        return allocator.dupe(u8, std.fs.path.basename(repo_path));
    };
    defer allocator.free(rel);

    if (rel.len == 0 or (rel.len == 1 and rel[0] == '.')) {
        return allocator.dupe(u8, std.fs.path.basename(repo_path));
    }
    return normalizePath(allocator, rel);
}

fn normalizePath(allocator: types.Allocator, input: []const u8) ![]const u8 {
    var buffer = try allocator.alloc(u8, input.len);
    var len: usize = 0;
    for (input) |ch| {
        buffer[len] = if (ch == '\\' or ch == '/') '/' else ch;
        len += 1;
    }
    while (len > 0 and buffer[len - 1] == '/') {
        len -= 1;
    }
    return buffer[0..len];
}

fn runGenerate(allocator: types.Allocator, parsed: args.Args, stdout: anytype, stderr: anytype) !void {
    _ = stderr;
    var parsed_cfg = try config.load(allocator, parsed.config_path);
    defer parsed_cfg.deinit();

    const cfg = parsed_cfg.value;
    const log = LogOptions{ .json = parsed.json };
    var log_mutex = std.Thread.Mutex{};
    const options = runner.RunOptions{
        .verbose = parsed.verbose,
        .log_file = std.fs.File.stderr(),
        .json = parsed.json,
        .insecure = parsed.insecure,
        .log_mutex = &log_mutex,
    };

    const site_root = try paths.outputPath(allocator, cfg.site.output_dir, cfg.site.path, "");
    defer allocator.free(site_root);

    if (!parsed.dry_run) {
        try fsutils.ensureDir(cfg.cache_dir);
        try fsutils.ensureDir(cfg.work_dir);
        try fsutils.ensureDir(site_root);

        const nojekyll = try std.fs.path.join(allocator, &.{ cfg.site.output_dir, ".nojekyll" });
        defer allocator.free(nojekyll);
        if (!fsutils.fileExists(nojekyll)) {
            try fsutils.writeFile(nojekyll, "");
        }

        try pruneCaches(allocator, cfg);
    }

    const results = try allocator.alloc(RepoTaskResult, cfg.repos.len);
    defer {
        for (results) |*result| {
            if (result.arena) |*arena| {
                arena.deinit();
            }
        }
        allocator.free(results);
    }
    for (results) |*result| {
        result.* = .{};
    }

    if (cfg.repos.len > 0) {
        const cpu_count = std.Thread.getCpuCount() catch 1;
        const worker_count = if (cpu_count == 0) @as(usize, 1) else @min(cfg.repos.len, cpu_count);
        if (worker_count <= 1) {
            var ctx = WorkerContext{
                .cfg = cfg,
                .repos = cfg.repos,
                .start_index = 0,
                .results = results,
                .dry_run = parsed.dry_run,
                .incremental = parsed.incremental,
                .options = options,
            };
            workerMain(&ctx);
        } else {
            const chunk = (cfg.repos.len + worker_count - 1) / worker_count;
            var threads = try allocator.alloc(std.Thread, worker_count);
            defer allocator.free(threads);
            var contexts = try allocator.alloc(WorkerContext, worker_count);
            defer allocator.free(contexts);

            var spawned: usize = 0;
            while (spawned < worker_count) : (spawned += 1) {
                const start = spawned * chunk;
                if (start >= cfg.repos.len) break;
                const end = @min(start + chunk, cfg.repos.len);
                contexts[spawned] = .{
                    .cfg = cfg,
                    .repos = cfg.repos[start..end],
                    .start_index = start,
                    .results = results,
                    .dry_run = parsed.dry_run,
                    .incremental = parsed.incremental,
                    .options = options,
                };
                threads[spawned] = try std.Thread.spawn(.{}, workerMain, .{ &contexts[spawned] });
            }

            var idx: usize = 0;
            while (idx < spawned) : (idx += 1) {
                threads[idx].join();
            }
        }
    }

    var index_arena = std.heap.ArenaAllocator.init(allocator);
    defer index_arena.deinit();
    const index_alloc = index_arena.allocator();
    var entries = std.ArrayList(index.RepoEntry).empty;
    defer entries.deinit(index_alloc);

    var first_error: ?anyerror = null;
    for (results, 0..) |result, idx| {
        const repo = cfg.repos[idx];
        if (result.err) |err| {
            if (first_error == null) first_error = err;
            try logRepoError(stdout, log, repo, err);
            continue;
        }
        if (result.outcome) |outcome| {
            if (!parsed.dry_run) {
                if (outcome.entry) |entry| {
                    try entries.append(index_alloc, entry);
                }
            }
            try logRepoOutcome(stdout, log, outcome);
        }
    }

    if (!parsed.dry_run) {
        try index.writeIndex(index_alloc, site_root, cfg.site, entries.items, cfg.index_template);
        _ = try inject.injectIndexFab(allocator, site_root);
    }

    if (first_error) |err| {
        return err;
    }
}

fn processRepo(
    allocator: types.Allocator,
    cfg: config.Config,
    repo: config.Repo,
    dry_run: bool,
    incremental: bool,
    options: runner.RunOptions,
) !ProcessOutcome {
    const src = source.parse(repo.source);
    const name = repo.name orelse try paths.baseNameFromSource(allocator, repo.source);
    const output_subpath = repo.output_subpath orelse name;
    const output_dir = try paths.outputPath(allocator, cfg.site.output_dir, cfg.site.path, output_subpath);

    if (dry_run) {
        var outcome = ProcessOutcome{
            .name = name,
            .output_dir = output_dir,
            .tool = null,
            .tool_inferred = false,
            .status = .dry_run,
        };
        if (repo.doc_tool) |tool| {
            outcome.tool = tool;
            outcome.tool_inferred = false;
        } else {
            const inferred = inferToolForDryRun(allocator, src) catch null;
            if (inferred) |tool| {
                outcome.tool = tool;
                outcome.tool_inferred = true;
            }
        }
        return outcome;
    }

    const materialized = try materializeRepo(allocator, cfg, repo, src, options);
    const filtered_path = try applyFilter(allocator, cfg, repo, output_subpath, materialized.path);
    const tool = repo.doc_tool orelse try doc_tool.infer(allocator, filtered_path);
    const resolved_doc_path = try doc_tool.resolveDocPath(allocator, tool, filtered_path, repo.doc_path);

    const ref_kind = if (repo.ref) |spec| spec.kind else if (materialized.ref_info) |info| info.kind else null;
    const ref_value = if (repo.ref) |spec| spec.value else if (materialized.ref_info) |info| info.ref else null;
    const commit_short = if (materialized.ref_info) |info| info.commit_short else null;

    const manifest_key_input = try std.mem.concat(allocator, u8, &.{ repo.source, "::", output_subpath });
    const manifest_key = try paths.cacheKey(allocator, manifest_key_input);
    const manifest_dir = try manifest.manifestDir(allocator, cfg.cache_dir);
    try fsutils.ensureDir(manifest_dir);
    const manifest_path = try manifest.manifestPath(allocator, cfg.cache_dir, manifest_key);

    const build_hash = computeBuildHash(repo, tool, resolved_doc_path, cfg.tool_templates);
    const current_manifest = manifest.RepoManifest{
        .source = repo.source,
        .output_subpath = output_subpath,
        .doc_tool = tool,
        .doc_path = resolved_doc_path,
        .ref_kind = ref_kind,
        .ref_value = ref_value,
        .commit_short = commit_short,
        .build_hash = build_hash,
    };

    const entry = try index.RepoEntry.init(allocator, .{
        .name = name,
        .output_subpath = output_subpath,
        .source = repo.source,
        .doc_tool = tool,
        .ref_kind = ref_kind,
        .ref_value = ref_value,
        .commit_short = commit_short,
    });

    if (incremental and fsutils.dirExists(output_dir)) {
        if (manifest.load(allocator, manifest_path) catch null) |loaded| {
            defer loaded.deinit();
            if (manifest.equals(current_manifest, loaded.value)) {
                return ProcessOutcome{
                    .name = name,
                    .output_dir = output_dir,
                    .tool = tool,
                    .tool_inferred = repo.doc_tool == null,
                    .status = .skipped,
                    .source_path = filtered_path,
                    .ref_info = materialized.ref_info,
                    .entry = entry,
                };
            }
        }
    }

    try fsutils.ensureEmptyDir(output_dir);
    const abs_output_dir = try std.fs.cwd().realpathAlloc(allocator, output_dir);
    defer allocator.free(abs_output_dir);

    try runHooks(allocator, repo.pre_build, filtered_path, options);
    try doc_tool.generate(allocator, tool, filtered_path, resolved_doc_path, abs_output_dir, options, cfg.tool_templates, repo.argv);
    try runHooks(allocator, repo.post_build, filtered_path, options);
    try manifest.save(manifest_path, current_manifest);

    return ProcessOutcome{
        .name = name,
        .output_dir = output_dir,
        .tool = tool,
        .tool_inferred = repo.doc_tool == null,
        .status = .built,
        .source_path = filtered_path,
        .ref_info = materialized.ref_info,
        .entry = entry,
    };
}

fn runDeploy(allocator: types.Allocator, parsed: args.Args, stdout: anytype, stderr: anytype) !void {
    var parsed_cfg = try config.load(allocator, parsed.config_path);
    defer parsed_cfg.deinit();

    const cfg = parsed_cfg.value;
    const config_dir = std.fs.path.dirname(parsed.config_path) orelse ".";

    try deploy.deploy(allocator, cfg, config_dir, .{
        .remote = parsed.deploy_remote,
        .branch = parsed.deploy_branch,
        .message = parsed.deploy_message,
        .dry_run = parsed.dry_run,
        .verbose = parsed.verbose,
        .log_file = std.fs.File.stderr(),
        .json = parsed.json,
        .insecure = parsed.insecure,
        .preserve_history = parsed.deploy_preserve_history,
    }, stdout, stderr);
}

fn runClean(allocator: types.Allocator, parsed: args.Args, stdout: anytype) !void {
    const log = LogOptions{ .json = parsed.json };
    var parsed_cfg = try config.load(allocator, parsed.config_path);
    defer parsed_cfg.deinit();

    const cfg = parsed_cfg.value;
    const site_root = try paths.outputPath(allocator, cfg.site.output_dir, cfg.site.path, "");
    defer allocator.free(site_root);

    const targets = [_][]const u8{ cfg.cache_dir, cfg.work_dir, site_root };
    for (targets) |target| {
        if (!fsutils.dirExists(target)) {
            continue;
        }
        if (parsed.dry_run) {
            try logEvent(stdout, log, .{ .event = "clean", .path = target, .action = "would-remove" }, "Would remove {s}\n", .{target});
            continue;
        }
        try std.fs.cwd().deleteTree(target);
        try logEvent(stdout, log, .{ .event = "clean", .path = target, .action = "removed" }, "Removed {s}\n", .{target});
    }
}

fn runList(allocator: types.Allocator, parsed: args.Args, stdout: anytype) !void {
    const log = LogOptions{ .json = parsed.json };
    var parsed_cfg = try config.load(allocator, parsed.config_path);
    defer parsed_cfg.deinit();
    const cfg = parsed_cfg.value;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const work = arena.allocator();

    if (log.json) {
        for (cfg.repos) |repo| {
            const row = try buildListRow(work, cfg, repo);
            try logEvent(stdout, log, .{
                .event = "list",
                .name = row.name,
                .tool = row.tool,
                .commit = row.commit,
            }, "", .{});
        }
        return;
    }

    var rows = std.ArrayList(ListRow).empty;
    defer rows.deinit(work);
    for (cfg.repos) |repo| {
        const row = try buildListRow(work, cfg, repo);
        try rows.append(work, row);
    }

    const header = ListRow{ .name = "Name", .tool = "Tool", .commit = "Commit" };
    const widths = computeListWidths(header, rows.items);
    try writeListRow(stdout, header, widths);
    try stdout.writeAll("\n");
    for (rows.items) |row| {
        try writeListRow(stdout, row, widths);
        try stdout.writeAll("\n");
    }
}

fn workerMain(ctx: *WorkerContext) void {
    for (ctx.repos, 0..) |repo, offset| {
        const idx = ctx.start_index + offset;
        ctx.results[idx].arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const repo_alloc = ctx.results[idx].arena.?.allocator();
        const outcome = processRepo(repo_alloc, ctx.cfg, repo, ctx.dry_run, ctx.incremental, ctx.options) catch |err| {
            ctx.results[idx].err = err;
            continue;
        };
        ctx.results[idx].outcome = outcome;
    }
}

const ListRow = struct {
    name: []const u8,
    tool: []const u8,
    commit: []const u8,
};

const ListWidths = struct {
    name: usize,
    tool: usize,
    commit: usize,
};

fn buildListRow(allocator: types.Allocator, cfg: config.Config, repo: config.Repo) !ListRow {
    const name = repo.name orelse try paths.baseNameFromSource(allocator, repo.source);
    const output_subpath = repo.output_subpath orelse name;

    var tool_label: []const u8 = "auto";
    var commit_label: []const u8 = "-";
    var inferred = false;

    if (repo.doc_tool) |tool| {
        tool_label = @tagName(tool);
    } else {
        const manifest_key_input = try std.mem.concat(allocator, u8, &.{ repo.source, "::", output_subpath });
        const manifest_key = try paths.cacheKey(allocator, manifest_key_input);
        const manifest_path = try manifest.manifestPath(allocator, cfg.cache_dir, manifest_key);
        if (manifest.load(allocator, manifest_path) catch null) |loaded| {
            defer loaded.deinit();
            tool_label = @tagName(loaded.value.doc_tool);
            if (loaded.value.commit_short) |commit| {
                commit_label = try allocator.dupe(u8, commit);
            } else if (loaded.value.ref_value) |ref| {
                commit_label = try allocator.dupe(u8, ref);
            }
        } else if (inferToolForDryRun(allocator, source.parse(repo.source)) catch null) |tool| {
            tool_label = @tagName(tool);
            inferred = true;
        }
    }

    if (inferred) {
        tool_label = try std.fmt.allocPrint(allocator, "{s} (inferred)", .{tool_label});
    }

    return ListRow{
        .name = name,
        .tool = tool_label,
        .commit = commit_label,
    };
}

fn computeListWidths(header: ListRow, rows: []const ListRow) ListWidths {
    var widths = ListWidths{
        .name = header.name.len,
        .tool = header.tool.len,
        .commit = header.commit.len,
    };
    for (rows) |row| {
        if (row.name.len > widths.name) widths.name = row.name.len;
        if (row.tool.len > widths.tool) widths.tool = row.tool.len;
        if (row.commit.len > widths.commit) widths.commit = row.commit.len;
    }
    return widths;
}

fn writeListRow(writer: anytype, row: ListRow, widths: ListWidths) !void {
    try writePadded(writer, row.name, widths.name);
    try writer.writeAll("  ");
    try writePadded(writer, row.tool, widths.tool);
    try writer.writeAll("  ");
    try writePadded(writer, row.commit, widths.commit);
}

fn writePadded(writer: anytype, text: []const u8, width: usize) !void {
    try writer.writeAll(text);
    if (text.len < width) {
        var i: usize = 0;
        while (i < width - text.len) : (i += 1) {
            try writer.writeByte(' ');
        }
    }
}

const MaterializedRepo = struct {
    path: []const u8,
    ref_info: ?git.RefInfo,
};

fn materializeRepo(
    allocator: types.Allocator,
    cfg: config.Config,
    repo: config.Repo,
    src: source.Source,
    options: runner.RunOptions,
) !MaterializedRepo {
    switch (src.kind) {
        .path => return materializePath(allocator, cfg, repo, src.value, options),
        .git_ssh, .git_https => return materializeGitUrl(allocator, cfg, repo, src.value, options),
        .archive_url => return materializeArchive(allocator, cfg, repo, src.value, options),
    }
}

fn materializePath(
    allocator: types.Allocator,
    cfg: config.Config,
    repo: config.Repo,
    path_input: []const u8,
    options: runner.RunOptions,
) !MaterializedRepo {
    const resolved = try std.fs.cwd().realpathAlloc(allocator, path_input);

    if (!git.isGitRepo(allocator, resolved)) {
        return .{ .path = resolved, .ref_info = null };
    }

    const ref_value = if (repo.ref) |spec| spec.value else "HEAD";
    const key_input = try std.mem.concat(allocator, u8, &.{ path_input, "::", ref_value });
    const key = try paths.cacheKey(allocator, key_input);
    const worktree_path = try std.fs.path.join(allocator, &.{ cfg.work_dir, key });

    try git.ensureWorktree(allocator, resolved, worktree_path, ref_value, options);

    var info = try git.inferRef(allocator, worktree_path, options);
    if (repo.ref) |spec| {
        info.ref = spec.value;
        info.kind = spec.kind;
    }

    return .{ .path = worktree_path, .ref_info = info };
}

fn materializeGitUrl(
    allocator: types.Allocator,
    cfg: config.Config,
    repo: config.Repo,
    url: []const u8,
    options: runner.RunOptions,
) !MaterializedRepo {
    const cache_key = try paths.cacheKey(allocator, url);
    const cache_path = try std.fs.path.join(allocator, &.{ cfg.cache_dir, cache_key });
    try git.ensureClone(allocator, url, cache_path, repo.shallow, options);

    const ref_value = if (repo.ref) |spec| spec.value else "HEAD";
    const work_key_input = try std.mem.concat(allocator, u8, &.{ url, "::", ref_value });
    const work_key = try paths.cacheKey(allocator, work_key_input);
    const worktree_path = try std.fs.path.join(allocator, &.{ cfg.work_dir, work_key });
    try git.ensureWorktree(allocator, cache_path, worktree_path, ref_value, options);

    var info = try git.inferRef(allocator, worktree_path, options);
    if (repo.ref) |spec| {
        info.ref = spec.value;
        info.kind = spec.kind;
    }

    return .{ .path = worktree_path, .ref_info = info };
}

fn materializeArchive(
    allocator: types.Allocator,
    cfg: config.Config,
    repo: config.Repo,
    url: []const u8,
    options: runner.RunOptions,
) !MaterializedRepo {
    _ = repo;
    const kind = archive.detectKind(url) orelse return error.UnsupportedArchive;
    const key = try paths.cacheKey(allocator, url);

    const ext = switch (kind) {
        .zip => ".zip",
        .tar => ".tar",
        .tar_gz => ".tar.gz",
    };

    const archive_name = try std.mem.concat(allocator, u8, &.{ key, ext });
    const archive_path = try std.fs.path.join(allocator, &.{ cfg.cache_dir, archive_name });

    if (!fsutils.fileExists(archive_path)) {
        try archive.download(allocator, url, archive_path, options);
    }

    const extract_dir = try std.fs.path.join(allocator, &.{ cfg.work_dir, key });
    try archive.extract(allocator, archive_path, extract_dir, kind, options);
    const root = try archive.resolveRoot(allocator, extract_dir);

    return .{ .path = root, .ref_info = null };
}

fn inferToolForDryRun(allocator: types.Allocator, src: source.Source) !types.DocTool {
    if (src.kind != .path) return doc_tool.InferError.ToolNotInferred;
    const resolved = try std.fs.cwd().realpathAlloc(allocator, src.value);
    defer allocator.free(resolved);
    return doc_tool.infer(allocator, resolved);
}

fn runHooks(allocator: types.Allocator, hooks: ?types.CommandList, cwd: []const u8, options: runner.RunOptions) !void {
    if (hooks) |list| {
        for (list) |argv| {
            if (argv.len == 0) return HookError.EmptyHookCommand;
            var result = try runner.runChecked(allocator, argv, cwd, options);
            result.deinit();
        }
    }
}

fn applyFilter(
    allocator: types.Allocator,
    cfg: config.Config,
    repo: config.Repo,
    output_subpath: []const u8,
    root_path: []const u8,
) ![]const u8 {
    if (repo.include == null and repo.exclude == null) return root_path;

    const include = repo.include orelse "";
    const exclude = repo.exclude orelse "";
    const key_input = try std.mem.concat(allocator, u8, &.{ repo.source, "::", output_subpath, "::", include, "::", exclude });
    const key = try paths.cacheKey(allocator, key_input);
    const filter_root = try std.fs.path.join(allocator, &.{ cfg.work_dir, "filter", key });
    try fsutils.ensureEmptyDir(filter_root);
    try fsutils.copyDirFiltered(allocator, root_path, filter_root, .{ .include = repo.include, .exclude = repo.exclude });
    return filter_root;
}

fn computeBuildHash(
    repo: config.Repo,
    tool: types.DocTool,
    resolved_doc_path: ?[]const u8,
    templates: ?types.ToolTemplates,
) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hashString(&hasher, @tagName(tool));
    if (resolved_doc_path) |path| hashString(&hasher, path);
    if (repo.include) |inc| hashString(&hasher, inc);
    if (repo.exclude) |exc| hashString(&hasher, exc);
    if (repo.argv) |argv| hashCommand(&hasher, argv);
    if (repo.pre_build) |list| hashCommandList(&hasher, list);
    if (repo.post_build) |list| hashCommandList(&hasher, list);
    if (toolTemplateFor(tool, templates)) |tpl| hashCommand(&hasher, tpl.argv);
    return hasher.final();
}

fn toolTemplateFor(tool: types.DocTool, templates: ?types.ToolTemplates) ?types.ToolTemplate {
    if (templates) |set| {
        return switch (tool) {
            .mkdocs => set.mkdocs,
            .sphinx => set.sphinx,
            .doxygen => set.doxygen,
            .godoc => set.godoc,
            .cargo => set.cargo,
            .shell => null,
        };
    }
    return null;
}

fn hashCommandList(hasher: *std.hash.Wyhash, list: types.CommandList) void {
    for (list) |argv| {
        hashCommand(hasher, argv);
        hasher.update(&[_]u8{0x1f});
    }
}

fn hashCommand(hasher: *std.hash.Wyhash, argv: types.Command) void {
    for (argv) |arg| {
        hashString(hasher, arg);
    }
    hasher.update(&[_]u8{0x1e});
}

fn hashString(hasher: *std.hash.Wyhash, input: []const u8) void {
    hasher.update(input);
    hasher.update(&[_]u8{0});
}

fn pruneCaches(allocator: types.Allocator, cfg: config.Config) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const work = arena.allocator();

    var git_keys = std.ArrayList([]const u8).empty;
    defer git_keys.deinit(work);
    var archive_keys = std.ArrayList([]const u8).empty;
    defer archive_keys.deinit(work);

    for (cfg.repos) |repo| {
        const src = source.parse(repo.source);
        switch (src.kind) {
            .git_ssh, .git_https => {
                const key = try paths.cacheKey(work, repo.source);
                try git_keys.append(work, key);
            },
            .archive_url => {
                const key = try paths.cacheKey(work, repo.source);
                try archive_keys.append(work, key);
            },
            else => {},
        }
    }

    try git.pruneCache(work, cfg.cache_dir, git_keys.items);
    try archive.pruneCache(work, cfg.cache_dir, archive_keys.items);
}

fn logRepoOutcome(writer: anytype, log: LogOptions, outcome: ProcessOutcome) !void {
    if (log.json) {
        const tool_name: ?[]const u8 = if (outcome.tool) |tool| @tagName(tool) else null;
        const ref_kind: ?[]const u8 = if (outcome.ref_info) |info| @tagName(info.kind) else null;
        const ref_value: ?[]const u8 = if (outcome.ref_info) |info| info.ref else null;
        const commit_short: ?[]const u8 = if (outcome.ref_info) |info| info.commit_short else null;
        try logEvent(writer, log, .{
            .event = "repo",
            .name = outcome.name,
            .output = outcome.output_dir,
            .status = @tagName(outcome.status),
            .tool = tool_name,
            .tool_inferred = outcome.tool_inferred,
            .source = outcome.source_path,
            .ref = ref_value,
            .ref_kind = ref_kind,
            .commit = commit_short,
        }, "", .{});
        return;
    }

    try writer.print("Repo {s} -> {s}\n", .{ outcome.name, outcome.output_dir });
    switch (outcome.status) {
        .dry_run => {
            if (outcome.tool) |tool| {
                if (outcome.tool_inferred) {
                    try writer.print("  tool: {s} (inferred)\n", .{@tagName(tool)});
                } else {
                    try writer.print("  tool: {s}\n", .{@tagName(tool)});
                }
            } else {
                try writer.writeAll("  tool: auto\n");
            }
        },
        .skipped => {
            try writer.writeAll("  status: up-to-date (skipped)\n");
        },
        .built => {
            if (outcome.source_path) |path| {
                try writer.print("  source: {s}\n", .{path});
            }
            if (outcome.tool) |tool| {
                try writer.print("  tool: {s}\n", .{@tagName(tool)});
            }
            if (outcome.ref_info) |info| {
                try writer.print("  ref: {s} ({s})\n", .{ info.ref, @tagName(info.kind) });
                try writer.print("  commit: {s}\n", .{info.commit_short});
            }
        },
    }
}

fn logRepoError(writer: anytype, log: LogOptions, repo: config.Repo, err: anyerror) !void {
    const name = repo.name orelse repo.source;
    if (log.json) {
        try logEvent(writer, log, .{
            .event = "repo-error",
            .name = name,
            .source = repo.source,
            .error_name = @errorName(err),
        }, "", .{});
        return;
    }
    try writer.print("Repo {s}: error {s}\n", .{ name, @errorName(err) });
}

fn logEvent(writer: anytype, log: LogOptions, value: anytype, comptime fmt: []const u8, fmt_args: anytype) !void {
    if (log.json) {
        const json_line = try std.json.Stringify.valueAlloc(std.heap.page_allocator, value, .{});
        defer std.heap.page_allocator.free(json_line);
        try writer.writeAll(json_line);
        try writer.writeAll("\n");
        return;
    }
    if (fmt.len > 0) {
        try writer.print(fmt, fmt_args);
    }
}

test "computeBuildHash changes with templates" {
    const repo = config.Repo{
        .source = "repo",
        .doc_tool = .mkdocs,
    };
    const tpl1 = types.ToolTemplates{
        .mkdocs = .{ .argv = &.{ "mkdocs", "build" } },
    };
    const tpl2 = types.ToolTemplates{
        .mkdocs = .{ .argv = &.{ "mkdocs", "build", "--clean" } },
    };
    const hash1 = computeBuildHash(repo, .mkdocs, null, tpl1);
    const hash2 = computeBuildHash(repo, .mkdocs, null, tpl2);
    try std.testing.expect(hash1 != hash2);
}

test "run prints usage in help mode" {
    // covers: app.run
    var out_buf: [2048]u8 = undefined;
    var err_buf: [2048]u8 = undefined;
    var out_stream = std.io.fixedBufferStream(&out_buf);
    var err_stream = std.io.fixedBufferStream(&err_buf);

    const parsed = args.Args{ .mode = .help };
    try run(std.testing.allocator, parsed, out_stream.writer(), err_stream.writer());

    const output = out_stream.getWritten();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "docforge usage"));
}
