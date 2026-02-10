const std = @import("std");
const types = @import("types.zig");
const paths = @import("paths.zig");

/// Top-level configuration loaded from docforge.json.
pub const Config = struct {
    /// GitHub Pages settings for output layout.
    site: Site,
    /// Cache directory for cloned repositories and downloads.
    cache_dir: []const u8 = ".docforge/cache",
    /// Work directory for extracted archives and worktrees.
    work_dir: []const u8 = ".docforge/work",
    /// Optional per-tool command templates.
    tool_templates: ?types.ToolTemplates = null,
    /// Optional HTML template path for the global index.
    index_template: ?[]const u8 = null,
    /// Repositories to document.
    repos: []Repo,
};

/// GitHub Pages layout settings.
pub const Site = struct {
    /// GitHub username (used for metadata only).
    username: []const u8,
    /// Path segment under username.github.io.
    path: []const u8,
    /// Output directory root for generated docs.
    output_dir: []const u8,
};

/// Repository configuration entry.
pub const Repo = struct {
    /// Optional friendly name for the repository.
    name: ?[]const u8 = null,
    /// Source path or URL.
    source: []const u8,
    /// Optional reference to checkout.
    ref: ?types.RefSpec = null,
    /// Optional doc tool override.
    doc_tool: ?types.DocTool = null,
    /// Optional path for docs (tool dependent).
    doc_path: ?[]const u8 = null,
    /// Optional output subpath override.
    output_subpath: ?[]const u8 = null,
    /// Optional include glob to filter repo contents.
    include: ?[]const u8 = null,
    /// Optional exclude glob to filter repo contents.
    exclude: ?[]const u8 = null,
    /// Optional command argv to run when using the shell tool.
    argv: ?types.Command = null,
    /// Optional pre-build commands to run before doc generation.
    pre_build: ?types.CommandList = null,
    /// Optional post-build commands to run after doc generation.
    post_build: ?types.CommandList = null,
    /// Use shallow clone/fetch for git remotes.
    shallow: bool = false,
};

/// Parsed config with arena-owned strings.
pub const ParsedConfig = struct {
    /// Parsed JSON with arena-backed strings.
    parsed: std.json.Parsed(Config),
    /// Parsed configuration.
    value: Config,

    /// Release the arena memory.
    pub fn deinit(self: *ParsedConfig) void {
        self.parsed.deinit();
    }
};

/// Load and parse the configuration from JSON.
pub fn load(allocator: types.Allocator, path: []const u8) !ParsedConfig {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(data);

    const parsed = try std.json.parseFromSlice(Config, allocator, data, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();
    var cfg = parsed.value;
    try expandEnvVars(parsed.arena.allocator(), &cfg);
    try validateConfig(parsed.arena.allocator(), cfg);

    return ParsedConfig{ .parsed = parsed, .value = cfg };
}

/// Errors returned while expanding or validating configs.
pub const ConfigError = error{
    MissingEnvVar,
    UnterminatedEnvVar,
    DuplicateOutputSubpath,
    OutputPathCollision,
};

fn expandEnvVars(allocator: types.Allocator, cfg: *Config) !void {
    for (cfg.repos) |*repo| {
        repo.source = try expandEnvVar(allocator, repo.source);
    }
}

fn expandEnvVar(allocator: types.Allocator, input: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '$' and i + 1 < input.len and input[i + 1] == '{') {
            const start = i + 2;
            const end = std.mem.indexOfScalarPos(u8, input, start, '}') orelse return ConfigError.UnterminatedEnvVar;
            const name = input[start..end];
            const value = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
                error.EnvironmentVariableNotFound => return ConfigError.MissingEnvVar,
                else => return err,
            };
            defer allocator.free(value);
            try out.appendSlice(allocator, value);
            i = end + 1;
            continue;
        }
        try out.append(allocator, input[i]);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

fn validateConfig(allocator: types.Allocator, cfg: Config) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const work = arena.allocator();

    var seen = std.StringHashMap(void).init(work);
    defer seen.deinit();

    const site_root = try std.fs.path.join(work, &.{ cfg.site.output_dir, cfg.site.path });

    for (cfg.repos) |repo| {
        const name = repo.name orelse try paths.baseNameFromSource(work, repo.source);
        const raw_subpath = repo.output_subpath orelse name;
        const normalized = try normalizeSubpath(work, raw_subpath);

        if (normalized.len == 0) {
            return ConfigError.OutputPathCollision;
        }

        if (seen.contains(normalized)) {
            return ConfigError.DuplicateOutputSubpath;
        }
        try seen.put(normalized, {});

        const repo_root = try std.fs.path.join(work, &.{ cfg.site.output_dir, cfg.site.path, normalized });
        if (std.mem.eql(u8, site_root, repo_root)) {
            return ConfigError.OutputPathCollision;
        }
    }
}

fn normalizeSubpath(allocator: types.Allocator, input: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i + 1 < input.len and input[i] == '.' and (input[i + 1] == '/' or input[i + 1] == '\\')) {
        i += 2;
    }

    while (i < input.len) : (i += 1) {
        const ch = if (input[i] == '\\') '/' else input[i];
        try out.append(allocator, ch);
    }

    while (out.items.len > 0 and out.items[out.items.len - 1] == '/') {
        out.items.len -= 1;
    }

    if (out.items.len == 1 and out.items[0] == '.') {
        out.items.len = 0;
    }

    return out.toOwnedSlice(allocator);
}

/// Write a starter configuration file to disk.
pub fn writeTemplate(path: []const u8, username: []const u8, site_path: []const u8, output_dir: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{ .exclusive = true });
    defer file.close();
    var buffer: [512]u8 = undefined;
    var writer = file.writer(&buffer);
    try writer.interface.print(
        "{{\n" ++
            "  \"site\": {{\n" ++
            "    \"username\": \"{s}\",\n" ++
            "    \"path\": \"{s}\",\n" ++
            "    \"output_dir\": \"{s}\"\n" ++
            "  }},\n" ++
            "  \"repos\": [\n" ++
            "    {{\n" ++
            "      \"name\": \"example\",\n" ++
            "      \"source\": \"../path/to/repo\",\n" ++
            "      \"ref\": {{ \"kind\": \"tag\", \"value\": \"v1.0.0\" }},\n" ++
            "      \"doc_tool\": \"mkdocs\"\n" ++
            "    }}\n" ++
            "  ]\n" ++
            "}}\n",
        .{ username, site_path, output_dir },
    );
    try writer.interface.flush();
}

/// Write a configuration file to disk as JSON.
pub fn write(path: []const u8, cfg: Config) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    var buffer: [2048]u8 = undefined;
    var writer = file.writer(&buffer);
    try std.json.Stringify.value(cfg, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, &writer.interface);
    try writer.interface.writeAll("\n");
    try writer.interface.flush();
}

test "config loads defaults" {
    const allocator = std.testing.allocator;
    const json =
        "{\n" ++
        "  \"site\": {\n" ++
        "    \"username\": \"sam\",\n" ++
        "    \"path\": \"docs\",\n" ++
        "    \"output_dir\": \"site\"\n" ++
        "  },\n" ++
        "  \"repos\": [\n" ++
        "    {\n" ++
        "      \"source\": \"../repo\"\n" ++
        "    }\n" ++
        "  ]\n" ++
        "}\n";

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(Config, arena.allocator(), json, .{});
    try std.testing.expectEqualStrings(".docforge/cache", parsed.value.cache_dir);
    try std.testing.expectEqualStrings(".docforge/work", parsed.value.work_dir);
    try std.testing.expect(parsed.value.tool_templates == null);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.repos.len);
}

test "config parses tool templates" {
    const allocator = std.testing.allocator;
    const json =
        "{\n" ++
        "  \"site\": {\n" ++
        "    \"username\": \"sam\",\n" ++
        "    \"path\": \"docs\",\n" ++
        "    \"output_dir\": \"site\"\n" ++
        "  },\n" ++
        "  \"tool_templates\": {\n" ++
        "    \"mkdocs\": {\n" ++
        "      \"argv\": [\"mkdocs\", \"build\", \"-d\", \"{output_dir}\"]\n" ++
        "    }\n" ++
        "  },\n" ++
        "  \"repos\": [\n" ++
        "    {\n" ++
        "      \"source\": \"../repo\"\n" ++
        "    }\n" ++
        "  ]\n" ++
        "}\n";

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(Config, arena.allocator(), json, .{});
    try std.testing.expect(parsed.value.tool_templates != null);
    const mkdocs = parsed.value.tool_templates.?.mkdocs orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqualStrings("mkdocs", mkdocs.argv[0]);
}

test "config parses hooks and shell argv" {
    const allocator = std.testing.allocator;
    const json =
        "{\n" ++
        "  \"site\": {\n" ++
        "    \"username\": \"sam\",\n" ++
        "    \"path\": \"docs\",\n" ++
        "    \"output_dir\": \"site\"\n" ++
        "  },\n" ++
        "  \"repos\": [\n" ++
        "    {\n" ++
        "      \"source\": \"../repo\",\n" ++
        "      \"doc_tool\": \"shell\",\n" ++
        "      \"argv\": [\"echo\", \"hi\"],\n" ++
        "      \"pre_build\": [[\"npm\", \"install\"]],\n" ++
        "      \"post_build\": [[\"npm\", \"run\", \"build\"]]\n" ++
        "    }\n" ++
        "  ]\n" ++
        "}\n";

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(Config, arena.allocator(), json, .{});
    try std.testing.expectEqual(types.DocTool.shell, parsed.value.repos[0].doc_tool.?);
    try std.testing.expectEqualStrings("echo", parsed.value.repos[0].argv.?[0]);
    try std.testing.expectEqualStrings("npm", parsed.value.repos[0].pre_build.?[0][0]);
    try std.testing.expectEqualStrings("npm", parsed.value.repos[0].post_build.?[0][0]);
}

test "config expands env vars" {
    // covers: config.load config.deinit
    const allocator = std.testing.allocator;
    const token = std.process.getEnvVarOwned(allocator, "HOME") catch return error.SkipZigTest;
    defer allocator.free(token);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const path = try std.fs.path.join(allocator, &.{ base, "config.json" });
    defer allocator.free(path);

    const json =
        "{\n" ++
        "  \"site\": {\n" ++
        "    \"username\": \"sam\",\n" ++
        "    \"path\": \"docs\",\n" ++
        "    \"output_dir\": \"site\"\n" ++
        "  },\n" ++
        "  \"repos\": [\n" ++
        "    { \"source\": \"https://example.com/${HOME}/repo.git\" }\n" ++
        "  ]\n" ++
        "}\n";

    try tmp.dir.writeFile(.{ .sub_path = "config.json", .data = json });
    var parsed = try load(allocator, path);
    defer parsed.deinit();
    const expected = try std.fmt.allocPrint(allocator, "https://example.com/{s}/repo.git", .{token});
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, parsed.value.repos[0].source);
}

test "config validation rejects duplicate output subpaths" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const path = try std.fs.path.join(allocator, &.{ base, "config.json" });
    defer allocator.free(path);
    const json =
        "{\n" ++
        "  \"site\": {\n" ++
        "    \"username\": \"sam\",\n" ++
        "    \"path\": \"docs\",\n" ++
        "    \"output_dir\": \"site\"\n" ++
        "  },\n" ++
        "  \"repos\": [\n" ++
        "    { \"source\": \"../repo1\", \"output_subpath\": \"same\" },\n" ++
        "    { \"source\": \"../repo2\", \"output_subpath\": \"same\" }\n" ++
        "  ]\n" ++
        "}\n";
    try tmp.dir.writeFile(.{ .sub_path = "config.json", .data = json });
    try std.testing.expectError(ConfigError.DuplicateOutputSubpath, load(allocator, path));
}

test "config validation rejects output path collision" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const path = try std.fs.path.join(allocator, &.{ base, "config.json" });
    defer allocator.free(path);
    const json =
        "{\n" ++
        "  \"site\": {\n" ++
        "    \"username\": \"sam\",\n" ++
        "    \"path\": \"docs\",\n" ++
        "    \"output_dir\": \"site\"\n" ++
        "  },\n" ++
        "  \"repos\": [\n" ++
        "    { \"source\": \"../repo1\", \"output_subpath\": \"\" }\n" ++
        "  ]\n" ++
        "}\n";
    try tmp.dir.writeFile(.{ .sub_path = "config.json", .data = json });
    try std.testing.expectError(ConfigError.OutputPathCollision, load(allocator, path));
}

test "config writeTemplate renders starter config" {
    // covers: config.writeTemplate
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const path = try std.fs.path.join(std.testing.allocator, &.{ base, "template.json" });
    defer std.testing.allocator.free(path);

    try writeTemplate(path, "sam", "docs", "site");

    const data = try tmp.dir.readFileAlloc(std.testing.allocator, "template.json", 4096);
    defer std.testing.allocator.free(data);
    try std.testing.expect(std.mem.containsAtLeast(u8, data, 1, "\"username\": \"sam\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, data, 1, "\"path\": \"docs\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, data, 1, "\"output_dir\": \"site\""));
}

test "config write emits json" {
    // covers: config.write
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const path = try std.fs.path.join(std.testing.allocator, &.{ base, "out.json" });
    defer std.testing.allocator.free(path);

    var repos = [_]Repo{.{ .source = "../repo" }};
    const cfg = Config{
        .site = .{ .username = "sam", .path = "docs", .output_dir = "site" },
        .repos = repos[0..],
    };

    try write(path, cfg);

    const data = try tmp.dir.readFileAlloc(std.testing.allocator, "out.json", 4096);
    defer std.testing.allocator.free(data);
    const parsed = try std.json.parseFromSlice(Config, std.testing.allocator, data, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("sam", parsed.value.site.username);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.repos.len);
}
