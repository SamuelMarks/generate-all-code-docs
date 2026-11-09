//! Documentation tool inference, default command generation, and custom template execution.

const std = @import("std");
const types = @import("types.zig");
const fsutils = @import("fsutils.zig");
const paths = @import("paths.zig");
const runner = @import("runner.zig");

/// Inference errors for doc tool detection.
pub const InferError = error{
    /// No documentation tool could be inferred from the repository's files.
    ToolNotInferred,
};

/// Template errors for custom command execution.
pub const TemplateError = error{
    /// A placeholder token in the template (`{doc_path}`, `{ref}`, etc.) had no value.
    MissingTemplateValue,
    /// A configured command template had an empty `argv` array.
    EmptyTemplate,
    /// A repository with `doc_tool = "shell"` did not provide an `argv` array.
    MissingShellArgv,
};

/// Context passed to documentation generators.
pub const GenerateContext = struct {
    /// Repository root path on disk.
    repo_root: []const u8,
    /// Output directory for generated documentation.
    output_dir: []const u8,
    /// Selected documentation tool.
    tool: types.DocTool,
    /// Optional tool-specific path override.
    doc_path: ?[]const u8,
    /// Repository display name.
    repo_name: []const u8,
    /// Original source value from config.
    source: []const u8,
    /// Reference value if checked out.
    ref: ?[]const u8 = null,
    /// Reference kind if checked out.
    ref_kind: ?types.RefKind = null,
    /// Short commit hash if inferred.
    commit_short: ?[]const u8 = null,
    /// Optional command template overrides.
    templates: ?types.ToolTemplates = null,
    /// Optional shell command argv when `tool` is `.shell`.
    repo_argv: ?types.Command = null,
    /// Runner options for subprocess logging.
    run_options: runner.RunOptions = .{},
};

/// Infer the documentation tool from files present in a repository root.
///
/// @param allocator Allocator for temporary path joins.
/// @param repo_root Filesystem path to the repository root.
/// @return Inferred `DocTool`, or `InferError.ToolNotInferred` if none matched.
pub fn infer(allocator: types.Allocator, repo_root: []const u8) (std.mem.Allocator.Error || InferError)!types.DocTool {
    if (try exists(allocator, repo_root, "mkdocs.yml") or try exists(allocator, repo_root, "mkdocs.yaml")) {
        return .mkdocs;
    }
    if (try exists(allocator, repo_root, "docs/conf.py") or try exists(allocator, repo_root, "conf.py")) {
        return .sphinx;
    }
    if (try exists(allocator, repo_root, "Doxyfile") or try exists(allocator, repo_root, "docs/Doxyfile")) {
        return .doxygen;
    }
    if (try exists(allocator, repo_root, "go.mod")) {
        return .godoc;
    }
    if (try exists(allocator, repo_root, "Cargo.toml")) {
        return .cargo;
    }
    return InferError.ToolNotInferred;
}

/// Generate documentation using the configured tool and context.
///
/// @param allocator Allocator for temporary buffers and subprocess execution.
/// @param ctx Generation context describing the repository, tool, and output directory.
pub fn generate(allocator: types.Allocator, ctx: GenerateContext) types.GenerateAllCodeDocsError!void {
    try fsutils.ensureEmptyDir(ctx.output_dir);
    const resolved_doc_path = try resolveDocPath(allocator, ctx.repo_root, ctx.tool, ctx.doc_path);
    const values = TemplateValues{
        .repo_root = ctx.repo_root,
        .output_dir = ctx.output_dir,
        .doc_path = resolved_doc_path,
        .repo_name = ctx.repo_name,
        .source = ctx.source,
        .ref = ctx.ref,
        .ref_kind = if (ctx.ref_kind) |kind| @tagName(kind) else null,
        .commit = ctx.commit_short,
    };
    const template = templateForTool(ctx.templates, ctx.tool);

    switch (ctx.tool) {
        .mkdocs => try generateMkdocs(allocator, ctx, template, values, resolved_doc_path),
        .sphinx => try generateSphinx(allocator, ctx, template, values, resolved_doc_path.?),
        .doxygen => try generateDoxygen(allocator, ctx, template, values, resolved_doc_path.?),
        .godoc => try generateGoDoc(allocator, ctx, template, values),
        .cargo => try generateCargoDoc(allocator, ctx, template, values, resolved_doc_path),
        .shell => try generateShell(allocator, ctx, values),
    }
}

/// Resolve the effective `doc_path` for a tool, returning a borrowed or static slice.
/// Does not allocate ownership to the caller.
///
/// @param allocator Allocator used only for temporary filesystem existence checks.
/// @param repo_root Repository root directory path.
/// @param tool Selected `DocTool`.
/// @param override Optional explicit `doc_path` from configuration.
/// @return Resolved relative doc path slice (borrowed from `override` or static string literal), or `null`.
pub fn resolveDocPath(
    allocator: types.Allocator,
    repo_root: []const u8,
    tool: types.DocTool,
    override: ?[]const u8,
) std.mem.Allocator.Error!?[]const u8 {
    return switch (tool) {
        .mkdocs, .godoc, .cargo, .shell => override,
        .sphinx => override orelse try inferSphinxPath(allocator, repo_root),
        .doxygen => override orelse try inferDoxygenPath(allocator, repo_root),
    };
}

/// Run MkDocs (`mkdocs build --clean -d <output_dir>` with optional `-f <doc_path>`).
///
/// @param allocator Allocator for subprocess execution.
/// @param ctx Generation context.
/// @param template Optional custom command template.
/// @param values Template placeholder values.
/// @param doc_path Optional MkDocs config file path.
fn generateMkdocs(
    allocator: types.Allocator,
    ctx: GenerateContext,
    template: ?types.ToolTemplate,
    values: TemplateValues,
    doc_path: ?[]const u8,
) types.GenerateAllCodeDocsError!void {
    if (template) |tpl| {
        try runTemplate(allocator, tpl, values, ctx.repo_root, ctx.run_options);
        return;
    }
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "mkdocs", "build", "--clean" });
    if (doc_path) |cfg_file| {
        try argv.appendSlice(allocator, &.{ "-f", cfg_file });
    }
    try argv.appendSlice(allocator, &.{ "-d", ctx.output_dir });
    var result = try runner.runChecked(allocator, argv.items, ctx.repo_root, ctx.run_options);
    result.deinit();
}

/// Run Sphinx (`sphinx-build -b html <doc_dir> <output_dir>`).
///
/// @param allocator Allocator for subprocess execution.
/// @param ctx Generation context.
/// @param template Optional custom command template.
/// @param values Template placeholder values.
/// @param doc_dir Sphinx documentation source directory.
fn generateSphinx(
    allocator: types.Allocator,
    ctx: GenerateContext,
    template: ?types.ToolTemplate,
    values: TemplateValues,
    doc_dir: []const u8,
) types.GenerateAllCodeDocsError!void {
    if (template) |tpl| {
        try runTemplate(allocator, tpl, values, ctx.repo_root, ctx.run_options);
        return;
    }
    var result = try runner.runChecked(allocator, &.{ "sphinx-build", "-b", "html", doc_dir, ctx.output_dir }, ctx.repo_root, ctx.run_options);
    result.deinit();
}

/// Run Doxygen by writing a temporary `Doxyfile.generate-all-code-docs` that overrides `OUTPUT_DIRECTORY` and `HTML_OUTPUT`.
///
/// @param allocator Allocator for path joins and subprocess execution.
/// @param ctx Generation context.
/// @param template Optional custom command template.
/// @param values Template placeholder values.
/// @param doxyfile Relative path to the base `Doxyfile`.
fn generateDoxygen(
    allocator: types.Allocator,
    ctx: GenerateContext,
    template: ?types.ToolTemplate,
    values: TemplateValues,
    doxyfile: []const u8,
) types.GenerateAllCodeDocsError!void {
    if (template) |tpl| {
        try runTemplate(allocator, tpl, values, ctx.repo_root, ctx.run_options);
        return;
    }
    const io = fsutils.defaultIo();
    const doxy_path = try std.Io.Dir.path.join(allocator, &.{ ctx.repo_root, "Doxyfile.generate-all-code-docs" });
    defer allocator.free(doxy_path);

    var file = try std.Io.Dir.cwd().createFile(io, doxy_path, .{ .truncate = true });
    defer file.close(io);

    var buffer: [1024]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    try writer.interface.print("@INCLUDE = {s}\x0a", .{doxyfile});
    try writer.interface.print("OUTPUT_DIRECTORY = {s}\x0a", .{ctx.output_dir});
    try writer.interface.writeAll("GENERATE_HTML = YES\x0a");
    try writer.interface.writeAll("HTML_OUTPUT = .\x0a");
    try writer.interface.flush();

    defer std.Io.Dir.cwd().deleteFile(io, doxy_path) catch {};

    var result = try runner.runChecked(allocator, &.{ "doxygen", doxy_path }, ctx.repo_root, ctx.run_options);
    result.deinit();
}

/// Generate HTML documentation for all Go packages via `go list ./...` and `go doc -all <pkg>`.
///
/// @param allocator Allocator for subprocess outputs and HTML rendering.
/// @param ctx Generation context.
/// @param template Optional custom command template.
/// @param values Template placeholder values.
fn generateGoDoc(
    allocator: types.Allocator,
    ctx: GenerateContext,
    template: ?types.ToolTemplate,
    values: TemplateValues,
) types.GenerateAllCodeDocsError!void {
    if (template) |tpl| {
        try runTemplate(allocator, tpl, values, ctx.repo_root, ctx.run_options);
        return;
    }
    const io = fsutils.defaultIo();
    var list_result = try runner.runChecked(allocator, &.{ "go", "list", "./..." }, ctx.repo_root, ctx.run_options);
    defer list_result.deinit();

    var packages = std.ArrayList([]const u8).empty;
    defer packages.deinit(allocator);

    var it = std.mem.splitScalar(u8, list_result.stdout, '\x0a');
    while (it.next()) |line| {
        const pkg = std.mem.trim(u8, line, " \x0d\x09");
        if (pkg.len == 0) continue;
        try packages.append(allocator, pkg);

        var doc_result = try runner.runChecked(allocator, &.{ "go", "doc", "-all", pkg }, ctx.repo_root, ctx.run_options);
        defer doc_result.deinit();

        const pkg_path = try packagePath(allocator, ctx.output_dir, pkg);
        defer allocator.free(pkg_path);
        if (std.Io.Dir.path.dirname(pkg_path)) |dir| {
            try fsutils.ensureDir(dir);
        }

        var file = try std.Io.Dir.cwd().createFile(io, pkg_path, .{ .truncate = true });
        defer file.close(io);

        var pkg_buffer: [1024]u8 = undefined;
        var pkg_writer = file.writerStreaming(io, &pkg_buffer);
        try pkg_writer.interface.writeAll("<!doctype html><html><head><meta charset=\x22utf-8\x22><title>");
        try paths.writeHtmlEscaped(&pkg_writer.interface, pkg);
        try pkg_writer.interface.writeAll("</title></head><body><pre>");
        try paths.writeHtmlEscaped(&pkg_writer.interface, doc_result.stdout);
        try pkg_writer.interface.writeAll("</pre></body></html>");
        try pkg_writer.interface.flush();
    }

    const index_path = try std.Io.Dir.path.join(allocator, &.{ ctx.output_dir, "index.html" });
    defer allocator.free(index_path);
    var index_file = try std.Io.Dir.cwd().createFile(io, index_path, .{ .truncate = true });
    defer index_file.close(io);

    var index_buffer: [1024]u8 = undefined;
    var index_writer = index_file.writerStreaming(io, &index_buffer);
    try index_writer.interface.writeAll("<!doctype html><html><head><meta charset=\x22utf-8\x22><title>Go packages</title></head><body><h1>Go packages</h1><ul>");
    for (packages.items) |pkg| {
        try index_writer.interface.writeAll("<li><a href=\x22pkg/");
        try paths.writeHtmlEscaped(&index_writer.interface, pkg);
        try index_writer.interface.writeAll(".html\x22>");
        try paths.writeHtmlEscaped(&index_writer.interface, pkg);
        try index_writer.interface.writeAll("</a></li>");
    }
    try index_writer.interface.writeAll("</ul></body></html>");
    try index_writer.interface.flush();
}

/// Generate Rust API docs via `cargo doc --no-deps --target-dir <tmp>` and copy `<tmp>/doc` to `output_dir`.
///
/// @param allocator Allocator for path joins and subprocess execution.
/// @param ctx Generation context.
/// @param template Optional custom command template.
/// @param values Template placeholder values.
/// @param doc_path Optional path to `Cargo.toml`.
fn generateCargoDoc(
    allocator: types.Allocator,
    ctx: GenerateContext,
    template: ?types.ToolTemplate,
    values: TemplateValues,
    doc_path: ?[]const u8,
) types.GenerateAllCodeDocsError!void {
    if (template) |tpl| {
        try runTemplate(allocator, tpl, values, ctx.repo_root, ctx.run_options);
        return;
    }
    const io = fsutils.defaultIo();
    const target_dir = try std.fmt.allocPrint(allocator, "{s}.cargo-target", .{ctx.output_dir});
    defer allocator.free(target_dir);
    try fsutils.ensureEmptyDir(target_dir);
    defer std.Io.Dir.cwd().deleteTree(io, target_dir) catch {};

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "cargo", "doc", "--no-deps", "--target-dir", target_dir });
    if (doc_path) |manifest_path| {
        try argv.appendSlice(allocator, &.{ "--manifest-path", manifest_path });
    }

    var result = try runner.runChecked(allocator, argv.items, ctx.repo_root, ctx.run_options);
    result.deinit();

    const doc_dir = try std.Io.Dir.path.join(allocator, &.{ target_dir, "doc" });
    defer allocator.free(doc_dir);
    try fsutils.copyDir(allocator, doc_dir, ctx.output_dir);
}

/// Run a custom repository shell command configured via `repo.argv`.
///
/// @param allocator Allocator for template expansion and subprocess execution.
/// @param ctx Generation context containing `repo_argv`.
/// @param values Template placeholder values.
fn generateShell(
    allocator: types.Allocator,
    ctx: GenerateContext,
    values: TemplateValues,
) types.GenerateAllCodeDocsError!void {
    const argv = ctx.repo_argv orelse return TemplateError.MissingShellArgv;
    const tpl = types.ToolTemplate{ .argv = argv };
    try runTemplate(allocator, tpl, values, ctx.repo_root, ctx.run_options);
}

/// Placeholder values substituted into custom command templates.
const TemplateValues = struct {
    /// Repository root directory (`{repo_root}`).
    repo_root: []const u8,
    /// Target output directory (`{output_dir}`).
    output_dir: []const u8,
    /// Tool-specific doc path (`{doc_path}`).
    doc_path: ?[]const u8,
    /// Repository display name (`{repo_name}`).
    repo_name: []const u8,
    /// Configured source string (`{source}`).
    source: []const u8,
    /// Checked-out git ref (`{ref}`).
    ref: ?[]const u8,
    /// Checked-out git ref kind (`{ref_kind}`).
    ref_kind: ?[]const u8,
    /// Short commit hash (`{commit}`).
    commit: ?[]const u8,
};

/// Look up an optional `ToolTemplate` override for `tool`.
///
/// @param templates Optional `ToolTemplates` configuration struct.
/// @param tool Target `DocTool`.
/// @return Matching `ToolTemplate` if configured, or `null`.
fn templateForTool(templates: ?types.ToolTemplates, tool: types.DocTool) ?types.ToolTemplate {
    if (templates == null) return null;
    return switch (tool) {
        .mkdocs => templates.?.mkdocs,
        .sphinx => templates.?.sphinx,
        .doxygen => templates.?.doxygen,
        .godoc => templates.?.godoc,
        .cargo => templates.?.cargo,
        .shell => null,
    };
}

/// Expand a `ToolTemplate` with `values` and execute the resulting command in `cwd`.
///
/// @param allocator Allocator for expanded arguments and subprocess output.
/// @param template Command template to expand.
/// @param values Placeholder values.
/// @param cwd Working directory for the command.
/// @param options Runner execution options.
fn runTemplate(
    allocator: types.Allocator,
    template: types.ToolTemplate,
    values: TemplateValues,
    cwd: []const u8,
    options: runner.RunOptions,
) types.GenerateAllCodeDocsError!void {
    if (template.argv.len == 0) return TemplateError.EmptyTemplate;
    const argv = try expandTemplate(allocator, template.argv, values);
    defer freeArgv(allocator, argv);
    var result = try runner.runChecked(allocator, argv, cwd, options);
    result.deinit();
}

/// Expand all placeholder tokens across every argument in `argv_template`.
///
/// @param allocator Allocator for the expanded argument array.
/// @param argv_template Slice of template argument strings.
/// @param values Placeholder values.
/// @return Owned slice of expanded argument strings (`freeArgv` to release).
fn expandTemplate(
    allocator: types.Allocator,
    argv_template: []const []const u8,
    values: TemplateValues,
) (std.mem.Allocator.Error || TemplateError)![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }

    for (argv_template) |arg| {
        const replaced = try substituteTemplate(allocator, arg, values);
        try out.append(allocator, replaced);
    }

    return out.toOwnedSlice(allocator);
}

/// Substitute `{repo_root}`, `{output_dir}`, `{doc_path}`, `{repo_name}`, `{source}`, `{ref}`, `{ref_kind}`, and `{commit}` in a single argument string.
///
/// @param allocator Allocator for the expanded string.
/// @param input Single template argument string.
/// @param values Placeholder values.
/// @return Newly allocated expanded argument string.
fn substituteTemplate(
    allocator: types.Allocator,
    input: []const u8,
    values: TemplateValues,
) (std.mem.Allocator.Error || TemplateError)![]const u8 {
    var current = try paths.replaceAll(allocator, input, "{repo_root}", values.repo_root);
    errdefer allocator.free(current);
    current = try paths.replaceAllOwned(allocator, current, "{output_dir}", values.output_dir);
    current = try replaceOptionalOwned(allocator, current, "{doc_path}", values.doc_path);
    current = try paths.replaceAllOwned(allocator, current, "{repo_name}", values.repo_name);
    current = try paths.replaceAllOwned(allocator, current, "{source}", values.source);
    current = try replaceOptionalOwned(allocator, current, "{ref}", values.ref);
    current = try replaceOptionalOwned(allocator, current, "{ref_kind}", values.ref_kind);
    current = try replaceOptionalOwned(allocator, current, "{commit}", values.commit);
    return current;
}

/// Replace an optional placeholder token in an owned string, returning `TemplateError.MissingTemplateValue` if the token is present and `value` is `null`.
///
/// @param allocator Allocator that owns `input` and allocates the replacement.
/// @param input Owned string slice to scan and replace.
/// @param token Placeholder token (e.g. `"{doc_path}"`).
/// @param value Optional replacement string.
/// @return `input` if `token` is absent, or a newly allocated string with `token` replaced (and `input` freed).
fn replaceOptionalOwned(
    allocator: types.Allocator,
    input: []const u8,
    token: []const u8,
    value: ?[]const u8,
) (std.mem.Allocator.Error || TemplateError)![]const u8 {
    if (std.mem.indexOf(u8, input, token) == null) return input;
    const actual = value orelse return TemplateError.MissingTemplateValue;
    return paths.replaceAllOwned(allocator, input, token, actual);
}

/// Infer the Sphinx source directory (`"docs"` if `docs/conf.py` exists, else `"."`).
///
/// @param allocator Allocator for temporary path join.
/// @param repo_root Repository root directory path.
/// @return Static string literal `"docs"` or `"."`.
fn inferSphinxPath(allocator: types.Allocator, repo_root: []const u8) std.mem.Allocator.Error![]const u8 {
    if (try exists(allocator, repo_root, "docs/conf.py")) {
        return "docs";
    }
    return ".";
}

/// Infer the Doxygen configuration path (`"Doxyfile"` if present at root, else `"docs/Doxyfile"`).
///
/// @param allocator Allocator for temporary path join.
/// @param repo_root Repository root directory path.
/// @return Static string literal `"Doxyfile"` or `"docs/Doxyfile"`.
fn inferDoxygenPath(allocator: types.Allocator, repo_root: []const u8) std.mem.Allocator.Error![]const u8 {
    if (try exists(allocator, repo_root, "Doxyfile")) {
        return "Doxyfile";
    }
    return "docs/Doxyfile";
}

/// Construct the output HTML file path (`<output_dir>/pkg/<pkg>.html`) for a Go package.
///
/// @param allocator Allocator for path strings.
/// @param output_dir Base output directory.
/// @param pkg Go package import path.
/// @return Full filesystem path to the package's HTML file.
fn packagePath(allocator: types.Allocator, output_dir: []const u8, pkg: []const u8) std.mem.Allocator.Error![]const u8 {
    const rel = try std.fmt.allocPrint(allocator, "pkg/{s}.html", .{pkg});
    defer allocator.free(rel);
    return std.Io.Dir.path.join(allocator, &.{ output_dir, rel });
}

/// Check if a relative file path exists under `root`.
///
/// @param allocator Allocator for joining `root` and `rel`.
/// @param root Base directory path.
/// @param rel Relative file path.
/// @return `true` if `root/rel` exists as a file.
fn exists(allocator: types.Allocator, root: []const u8, rel: []const u8) std.mem.Allocator.Error!bool {
    const full = try std.Io.Dir.path.join(allocator, &.{ root, rel });
    defer allocator.free(full);
    return fsutils.fileExists(full);
}

/// Free an owned slice of owned argument strings.
///
/// @param allocator Allocator that allocated the slice and strings.
/// @param argv Slice of strings to release.
fn freeArgv(allocator: types.Allocator, argv: [][]const u8) void {
    for (argv) |arg| {
        allocator.free(arg);
    }
    allocator.free(argv);
}

test "infer detects mkdocs, sphinx, doxygen, godoc, cargo, and ToolNotInferred" {
    // covers: doc_tool.infer doc_tool.exists
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    try std.testing.expectError(InferError.ToolNotInferred, infer(std.testing.allocator, root));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Cargo.toml", .data = "[package]\x0aname = \x22x\x22\x0a" });
    try std.testing.expectEqual(types.DocTool.cargo, try infer(std.testing.allocator, root));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "go.mod", .data = "module x\x0a" });
    try std.testing.expectEqual(types.DocTool.godoc, try infer(std.testing.allocator, root));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Doxyfile", .data = "PROJECT_NAME = x\x0a" });
    try std.testing.expectEqual(types.DocTool.doxygen, try infer(std.testing.allocator, root));

    try tmp.dir.createDirPath(std.testing.io, "docs");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "docs/conf.py", .data = "project = 'x'\x0a" });
    try std.testing.expectEqual(types.DocTool.sphinx, try infer(std.testing.allocator, root));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "mkdocs.yml", .data = "site_name: demo\x0a" });
    try std.testing.expectEqual(types.DocTool.mkdocs, try infer(std.testing.allocator, root));
}

test "resolveDocPath covers all tools and fallback paths" {
    // covers: doc_tool.resolveDocPath doc_tool.inferSphinxPath doc_tool.inferDoxygenPath
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    try std.testing.expect((try resolveDocPath(std.testing.allocator, root, .mkdocs, null)) == null);
    try std.testing.expectEqualStrings("custom.yml", (try resolveDocPath(std.testing.allocator, root, .mkdocs, "custom.yml")).?);

    try std.testing.expectEqualStrings(".", (try resolveDocPath(std.testing.allocator, root, .sphinx, null)).?);
    try std.testing.expectEqualStrings("docs/Doxyfile", (try resolveDocPath(std.testing.allocator, root, .doxygen, null)).?);

    try tmp.dir.createDirPath(std.testing.io, "docs");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "docs/conf.py", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Doxyfile", .data = "" });

    try std.testing.expectEqualStrings("docs", (try resolveDocPath(std.testing.allocator, root, .sphinx, null)).?);
    try std.testing.expectEqualStrings("Doxyfile", (try resolveDocPath(std.testing.allocator, root, .doxygen, null)).?);
}

test "generate executes mkdocs, sphinx, doxygen, godoc, cargo, and shell (default and templates)" {
    // covers: doc_tool.generate doc_tool.generateMkdocs doc_tool.generateSphinx doc_tool.generateDoxygen doc_tool.generateGoDoc doc_tool.generateCargoDoc doc_tool.generateShell doc_tool.templateForTool doc_tool.runTemplate doc_tool.expandTemplate doc_tool.substituteTemplate doc_tool.replaceOptionalOwned doc_tool.packagePath doc_tool.freeArgv
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const repo_root = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "repo" });
    defer std.testing.allocator.free(repo_root);
    const out_dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "out" });
    defer std.testing.allocator.free(out_dir);
    try tmp.dir.createDirPath(std.testing.io, "repo");

    const fake = runner.TestRunner{ .run = struct {
        fn runFn(alloc: types.Allocator, argv: []const []const u8, _: ?[]const u8, _: runner.RunOptions) types.GenerateAllCodeDocsError!runner.RunResult {
            clearTestArgs();
            test_last_len = argv.len;
            for (argv, 0..) |arg, idx| {
                if (idx < test_last_argv.len) {
                    test_last_argv[idx] = try std.testing.allocator.dupe(u8, arg);
                }
            }
            if (argv.len >= 2 and std.mem.eql(u8, argv[0], "go") and std.mem.eql(u8, argv[1], "list")) {
                const out = try alloc.dupe(u8, "example.com/mod/pkg1\x0a\x0a");
                const err = try alloc.alloc(u8, 0);
                return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .exited = 0 }, .allocator = alloc };
            }
            if (argv.len >= 2 and std.mem.eql(u8, argv[0], "go") and std.mem.eql(u8, argv[1], "doc")) {
                const out = try alloc.dupe(u8, "package pkg1 // <doc>\x0a");
                const err = try alloc.alloc(u8, 0);
                return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .exited = 0 }, .allocator = alloc };
            }
            if (argv.len >= 2 and std.mem.eql(u8, argv[0], "cargo") and std.mem.eql(u8, argv[1], "doc")) {
                for (argv, 0..) |item, i| {
                    if (std.mem.eql(u8, item, "--target-dir") and i + 1 < argv.len) {
                        const doc_sub = try std.Io.Dir.path.join(alloc, &.{ argv[i + 1], "doc" });
                        defer alloc.free(doc_sub);
                        try fsutils.ensureDir(doc_sub);
                        const idx_file = try std.Io.Dir.path.join(alloc, &.{ doc_sub, "index.html" });
                        defer alloc.free(idx_file);
                        try fsutils.writeFile(idx_file, "<html>cargo</html>");
                    }
                }
            }
            const out = try alloc.alloc(u8, 0);
            const err = try alloc.alloc(u8, 0);
            return runner.RunResult{ .stdout = out, .stderr = err, .term = .{ .exited = 0 }, .allocator = alloc };
        }
    }.runFn };

    runner.setTestRunner(fake);
    defer runner.setTestRunner(null);
    defer clearTestArgs();

    // 1. Default MkDocs with doc_path
    try generate(std.testing.allocator, .{
        .repo_root = repo_root,
        .output_dir = out_dir,
        .tool = .mkdocs,
        .doc_path = "mkdocs.yml",
        .repo_name = "demo",
        .source = "src",
    });
    try std.testing.expectEqualStrings("mkdocs", test_last_argv[0]);
    try std.testing.expectEqualStrings("-f", test_last_argv[3]);
    try std.testing.expectEqualStrings("mkdocs.yml", test_last_argv[4]);

    // 2. Default Sphinx
    try generate(std.testing.allocator, .{
        .repo_root = repo_root,
        .output_dir = out_dir,
        .tool = .sphinx,
        .doc_path = null,
        .repo_name = "demo",
        .source = "src",
    });
    try std.testing.expectEqualStrings("sphinx-build", test_last_argv[0]);

    // 3. Default Doxygen
    try generate(std.testing.allocator, .{
        .repo_root = repo_root,
        .output_dir = out_dir,
        .tool = .doxygen,
        .doc_path = "Doxyfile",
        .repo_name = "demo",
        .source = "src",
    });
    try std.testing.expectEqualStrings("doxygen", test_last_argv[0]);

    // 4. Default GoDoc
    try generate(std.testing.allocator, .{
        .repo_root = repo_root,
        .output_dir = out_dir,
        .tool = .godoc,
        .doc_path = null,
        .repo_name = "demo",
        .source = "src",
    });
    const go_idx = try std.Io.Dir.path.join(std.testing.allocator, &.{ out_dir, "index.html" });
    defer std.testing.allocator.free(go_idx);
    try std.testing.expect(fsutils.fileExists(go_idx));

    // 5. Default CargoDoc with doc_path
    try generate(std.testing.allocator, .{
        .repo_root = repo_root,
        .output_dir = out_dir,
        .tool = .cargo,
        .doc_path = "Cargo.toml",
        .repo_name = "demo",
        .source = "src",
    });
    const cargo_idx = try std.Io.Dir.path.join(std.testing.allocator, &.{ out_dir, "index.html" });
    defer std.testing.allocator.free(cargo_idx);
    try std.testing.expect(fsutils.fileExists(cargo_idx));

    // 6. Custom templates for all tools
    const tpl = types.ToolTemplate{ .argv = &.{ "custom", "{repo_root}", "{output_dir}", "{repo_name}", "{source}", "{ref}", "{ref_kind}", "{commit}" } };
    const templates = types.ToolTemplates{
        .mkdocs = tpl,
        .sphinx = tpl,
        .doxygen = tpl,
        .godoc = tpl,
        .cargo = tpl,
    };
    inline for (.{ types.DocTool.mkdocs, types.DocTool.sphinx, types.DocTool.doxygen, types.DocTool.godoc, types.DocTool.cargo }) |t| {
        try generate(std.testing.allocator, .{
            .repo_root = repo_root,
            .output_dir = out_dir,
            .tool = t,
            .doc_path = null,
            .repo_name = "demo",
            .source = "src",
            .ref = "v1.0",
            .ref_kind = .tag,
            .commit_short = "1234567",
            .templates = templates,
        });
        try std.testing.expectEqualStrings("custom", test_last_argv[0]);
    }

    // 7. Shell tool and error cases
    try generate(std.testing.allocator, .{
        .repo_root = repo_root,
        .output_dir = out_dir,
        .tool = .shell,
        .doc_path = null,
        .repo_name = "demo",
        .source = "src",
        .repo_argv = &.{ "sh", "-c", "echo {output_dir}" },
    });
    try std.testing.expectEqualStrings("sh", test_last_argv[0]);

    try std.testing.expectError(TemplateError.MissingShellArgv, generate(std.testing.allocator, .{
        .repo_root = repo_root,
        .output_dir = out_dir,
        .tool = .shell,
        .doc_path = null,
        .repo_name = "demo",
        .source = "src",
        .repo_argv = null,
    }));

    try std.testing.expectError(TemplateError.EmptyTemplate, generate(std.testing.allocator, .{
        .repo_root = repo_root,
        .output_dir = out_dir,
        .tool = .shell,
        .doc_path = null,
        .repo_name = "demo",
        .source = "src",
        .repo_argv = &.{},
    }));

    try std.testing.expectError(TemplateError.MissingTemplateValue, generate(std.testing.allocator, .{
        .repo_root = repo_root,
        .output_dir = out_dir,
        .tool = .shell,
        .doc_path = null,
        .repo_name = "demo",
        .source = "src",
        .repo_argv = &.{ "echo", "{commit}" },
    }));
}

/// Free all duplicated strings in `test_last_argv`.
fn clearTestArgs() void {
    var idx: usize = 0;
    while (idx < test_last_len) : (idx += 1) {
        std.testing.allocator.free(test_last_argv[idx]);
    }
    test_last_len = 0;
}

/// Captured argument array for `doc_tool` unit tests.
var test_last_argv: [16][]const u8 = undefined;
/// Number of captured arguments in `test_last_argv`.
var test_last_len: usize = 0;
