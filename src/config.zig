//! Loading, environment variable expansion, validation, and JSON serialization of `generate-all-code-docs.json`.

const std = @import("std");
const types = @import("types.zig");
const paths = @import("paths.zig");
const fsutils = @import("fsutils.zig");

/// Top-level configuration loaded from `generate-all-code-docs.json`.
pub const Config = struct {
    /// GitHub Pages settings for output layout.
    site: Site,
    /// Cache directory for cloned repositories and downloads.
    cache_dir: []const u8 = ".generate-all-code-docs/cache",
    /// Work directory for extracted archives and worktrees.
    work_dir: []const u8 = ".generate-all-code-docs/work",
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
    /// Path segment under `username.github.io`.
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
    /// Optional exclude glob to skip files and directories.
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
    ///
    /// @param self Pointer to the `ParsedConfig` instance to deinitialize.
    pub fn deinit(self: *ParsedConfig) void {
        self.parsed.deinit();
    }
};

/// Errors returned while expanding or validating configs.
pub const ConfigError = error{
    /// A referenced `${VAR}` environment variable was missing or empty.
    MissingEnvVar,
    /// A `${VAR` placeholder in a source string lacked a closing `}`.
    UnterminatedEnvVar,
    /// Two or more repositories resolved to the same output subpath.
    DuplicateOutputSubpath,
    /// A repository output subpath collided with the site root or attempted `..` traversal.
    OutputPathCollision,
};

/// Load, expand environment variables, and validate a configuration from a JSON file.
///
/// @param allocator Backing allocator for reading the file and initializing the JSON arena.
/// @param path Filesystem path to the configuration JSON file.
/// @return Validated `ParsedConfig` owned by caller.
pub fn load(allocator: types.Allocator, path: []const u8) types.GenerateAllCodeDocsError!ParsedConfig {
    const io = fsutils.defaultIo();
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
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

/// Expand `${VAR}` placeholders in all `cfg.repos[i].source` strings in place.
///
/// @param allocator Arena allocator for expanded source strings.
/// @param cfg Mutable pointer to the `Config` being loaded.
fn expandEnvVars(allocator: types.Allocator, cfg: *Config) (std.mem.Allocator.Error || ConfigError)!void {
    for (cfg.repos) |*repo| {
        repo.source = try expandEnvVar(allocator, repo.source);
    }
}

/// Look up an environment variable by name and return an owned copy of its value.
///
/// @param allocator Allocator for the variable value copy.
/// @param name Environment variable name (must be non-empty).
/// @return Owned slice containing the environment variable value, or `ConfigError.MissingEnvVar`.
fn getEnvVarOwned(allocator: types.Allocator, name: []const u8) (std.mem.Allocator.Error || ConfigError)![]u8 {
    if (name.len == 0) return ConfigError.MissingEnvVar;
    const environ = if (@import("builtin").is_test)
        std.testing.environ
    else
        std.Options.debug_threaded_io.?.environ.process_environ;
    return environ.getAlloc(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableMissing, error.InvalidWtf8 => return ConfigError.MissingEnvVar,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

/// Expand all `${VAR}` tokens in `input` using process environment variables.
///
/// @param allocator Allocator for the expanded string.
/// @param input Source string potentially containing `${VAR}` tokens.
/// @return Newly allocated string with all environment variables expanded.
fn expandEnvVar(allocator: types.Allocator, input: []const u8) (std.mem.Allocator.Error || ConfigError)![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '$' and i + 1 < input.len and input[i + 1] == '{') {
            const start = i + 2;
            const end = std.mem.indexOfScalarPos(u8, input, start, '}') orelse return ConfigError.UnterminatedEnvVar;
            const name = input[start..end];
            const value = try getEnvVarOwned(allocator, name);
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

/// Validate that no two repositories resolve to the same normalized output subpath and none collide with the site root.
///
/// @param allocator Backing allocator for temporary validation structures.
/// @param cfg Configuration to validate.
fn validateConfig(allocator: types.Allocator, cfg: Config) (std.mem.Allocator.Error || ConfigError)!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const work = arena.allocator();

    var seen = std.StringHashMap(void).init(work);
    defer seen.deinit();

    for (cfg.repos) |repo| {
        const name = repo.name orelse try paths.baseNameFromSource(work, repo.source);
        const raw_subpath = repo.output_subpath orelse name;
        const normalized = try paths.normalizeSubpath(work, raw_subpath);

        if (normalized.len == 0) {
            return ConfigError.OutputPathCollision;
        }

        if (seen.contains(normalized)) {
            return ConfigError.DuplicateOutputSubpath;
        }
        try seen.put(normalized, {});
    }
}

/// Write a starter configuration file to disk using structured JSON serialization (preventing JSON injection).
/// Fails if `path` already exists (`exclusive = true`).
///
/// @param path Destination configuration file path.
/// @param username GitHub Pages username.
/// @param site_path GitHub Pages site path segment.
/// @param output_dir Output directory root.
pub fn writeTemplate(
    path: []const u8,
    username: []const u8,
    site_path: []const u8,
    output_dir: []const u8,
) (std.Io.File.OpenError || std.Io.File.Writer.Error || std.Io.Writer.Error)!void {
    const io = fsutils.defaultIo();
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer file.close(io);

    var example_repos = [_]Repo{.{
        .name = "example",
        .source = "../path/to/repo",
        .ref = .{ .kind = .tag, .value = "v1.0.0" },
        .doc_tool = .mkdocs,
    }};
    const template_cfg = Config{
        .site = .{
            .username = username,
            .path = site_path,
            .output_dir = output_dir,
        },
        .repos = example_repos[0..],
    };

    var buffer: [1024]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    try std.json.Stringify.value(template_cfg, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, &writer.interface);
    try writer.interface.writeAll("\x0a");
    try writer.interface.flush();
}

/// Write a `Config` struct to disk as pretty-printed JSON.
///
/// @param path Destination configuration file path.
/// @param cfg Configuration structure to serialize.
pub fn write(path: []const u8, cfg: Config) (std.Io.File.OpenError || std.Io.File.Writer.Error || std.Io.Writer.Error)!void {
    const io = fsutils.defaultIo();
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    var buffer: [2048]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    try std.json.Stringify.value(cfg, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, &writer.interface);
    try writer.interface.writeAll("\x0a");
    try writer.interface.flush();
}

test "config loads defaults and tool templates and hooks" {
    const allocator = std.testing.allocator;
    const json =
        "{\x0a" ++
        "  \x22site\x22: {\x0a" ++
        "    \x22username\x22: \x22sam\x22,\x0a" ++
        "    \x22path\x22: \x22docs\x22,\x0a" ++
        "    \x22output_dir\x22: \x22site\x22\x0a" ++
        "  },\x0a" ++
        "  \x22tool_templates\x22: {\x0a" ++
        "    \x22mkdocs\x22: {\x0a" ++
        "      \x22argv\x22: [\x22mkdocs\x22, \x22build\x22, \x22-d\x22, \x22{output_dir}\x22]\x0a" ++
        "    }\x0a" ++
        "  },\x0a" ++
        "  \x22repos\x22: [\x0a" ++
        "    {\x0a" ++
        "      \x22source\x22: \x22../repo\x22,\x0a" ++
        "      \x22doc_tool\x22: \x22shell\x22,\x0a" ++
        "      \x22argv\x22: [\x22echo\x22, \x22hi\x22],\x0a" ++
        "      \x22pre_build\x22: [[\x22npm\x22, \x22install\x22]],\x0a" ++
        "      \x22post_build\x22: [[\x22npm\x22, \x22run\x22, \x22build\x22]]\x0a" ++
        "    }\x0a" ++
        "  ]\x0a" ++
        "}\x0a";

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(Config, arena.allocator(), json, .{});
    try std.testing.expectEqualStrings(".generate-all-code-docs/cache", parsed.value.cache_dir);
    try std.testing.expectEqualStrings(".generate-all-code-docs/work", parsed.value.work_dir);
    try std.testing.expect(parsed.value.tool_templates != null);
    try std.testing.expectEqualStrings("mkdocs", parsed.value.tool_templates.?.mkdocs.?.argv[0]);
    try std.testing.expectEqual(types.DocTool.shell, parsed.value.repos[0].doc_tool.?);
    try std.testing.expectEqualStrings("echo", parsed.value.repos[0].argv.?[0]);
    try std.testing.expectEqualStrings("npm", parsed.value.repos[0].pre_build.?[0][0]);
    try std.testing.expectEqualStrings("npm", parsed.value.repos[0].post_build.?[0][0]);
}

test "config expands env vars and rejects missing or unterminated env vars" {
    // covers: config.load config.deinit config.expandEnvVars config.getEnvVarOwned config.expandEnvVar
    const allocator = std.testing.allocator;
    const token = getEnvVarOwned(allocator, "HOME") catch return error.SkipZigTest;
    defer allocator.free(token);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(base);
    const path = try std.Io.Dir.path.join(allocator, &.{ base, "config.json" });
    defer allocator.free(path);

    const json =
        "{\x0a" ++
        "  \x22site\x22: {\x0a" ++
        "    \x22username\x22: \x22sam\x22,\x0a" ++
        "    \x22path\x22: \x22docs\x22,\x0a" ++
        "    \x22output_dir\x22: \x22site\x22\x0a" ++
        "  },\x0a" ++
        "  \x22repos\x22: [\x0a" ++
        "    { \x22source\x22: \x22https://example.com/${HOME}/${HOME}/repo.git\x22 }\x0a" ++
        "  ]\x0a" ++
        "}\x0a";

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.json", .data = json });
    var parsed = try load(allocator, path);
    defer parsed.deinit();
    const expected = try std.fmt.allocPrint(allocator, "https://example.com/{s}/{s}/repo.git", .{ token, token });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, parsed.value.repos[0].source);

    try std.testing.expectError(ConfigError.UnterminatedEnvVar, expandEnvVar(allocator, "https://example.com/${UNTERMINATED"));
    try std.testing.expectError(ConfigError.MissingEnvVar, expandEnvVar(allocator, "https://example.com/${}"));
    try std.testing.expectError(ConfigError.MissingEnvVar, expandEnvVar(allocator, "https://example.com/${GENERATE_ALL_CODE_DOCS_DEFINITELY_MISSING_VAR_99999}"));
}

test "config validation rejects duplicate output subpaths and collisions" {
    // covers: config.validateConfig
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(base);
    const path = try std.Io.Dir.path.join(allocator, &.{ base, "config.json" });
    defer std.testing.allocator.free(path);

    const dup_json =
        "{\x0a" ++
        "  \x22site\x22: {\x0a" ++
        "    \x22username\x22: \x22sam\x22,\x0a" ++
        "    \x22path\x22: \x22docs\x22,\x0a" ++
        "    \x22output_dir\x22: \x22site\x22\x0a" ++
        "  },\x0a" ++
        "  \x22repos\x22: [\x0a" ++
        "    { \x22source\x22: \x22../repo1\x22, \x22output_subpath\x22: \x22same\x22 },\x0a" ++
        "    { \x22source\x22: \x22../repo2\x22, \x22output_subpath\x22: \x22./same/\x22 }\x0a" ++
        "  ]\x0a" ++
        "}\x0a";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.json", .data = dup_json });
    try std.testing.expectError(ConfigError.DuplicateOutputSubpath, load(allocator, path));

    const empty_json =
        "{\x0a" ++
        "  \x22site\x22: {\x0a" ++
        "    \x22username\x22: \x22sam\x22,\x0a" ++
        "    \x22path\x22: \x22docs\x22,\x0a" ++
        "    \x22output_dir\x22: \x22site\x22\x0a" ++
        "  },\x0a" ++
        "  \x22repos\x22: [\x0a" ++
        "    { \x22source\x22: \x22../repo1\x22, \x22output_subpath\x22: \x22.\x22 }\x0a" ++
        "  ]\x0a" ++
        "}\x0a";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.json", .data = empty_json });
    try std.testing.expectError(ConfigError.OutputPathCollision, load(allocator, path));

    const traversal_json =
        "{\x0a" ++
        "  \x22site\x22: {\x0a" ++
        "    \x22username\x22: \x22sam\x22,\x0a" ++
        "    \x22path\x22: \x22docs\x22,\x0a" ++
        "    \x22output_dir\x22: \x22site\x22\x0a" ++
        "  },\x0a" ++
        "  \x22repos\x22: [\x0a" ++
        "    { \x22source\x22: \x22../repo1\x22, \x22output_subpath\x22: \x22../escape\x22 }\x0a" ++
        "  ]\x0a" ++
        "}\x0a";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.json", .data = traversal_json });
    try std.testing.expectError(ConfigError.OutputPathCollision, load(allocator, path));
}

test "config writeTemplate safely escapes special JSON characters and loads back" {
    // covers: config.writeTemplate
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const path = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "template.json" });
    defer std.testing.allocator.free(path);

    try writeTemplate(path, "sam\x22quote", "docs\x5cslash", "site");

    var loaded = try load(std.testing.allocator, path);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("sam\x22quote", loaded.value.site.username);
    try std.testing.expectEqualStrings("docs\x5cslash", loaded.value.site.path);
    try std.testing.expectEqualStrings("site", loaded.value.site.output_dir);
}

test "config write emits valid json" {
    // covers: config.write
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const path = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "out.json" });
    defer std.testing.allocator.free(path);

    var repos = [_]Repo{.{ .source = "../repo" }};
    const cfg = Config{
        .site = .{ .username = "sam", .path = "docs", .output_dir = "site" },
        .repos = repos[0..],
    };

    try write(path, cfg);

    var loaded = try load(std.testing.allocator, path);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("sam", loaded.value.site.username);
    try std.testing.expectEqual(@as(usize, 1), loaded.value.repos.len);
}
