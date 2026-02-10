const std = @import("std");
const types = @import("types.zig");
const fsutils = @import("fsutils.zig");
const runner = @import("runner.zig");

/// Inference errors for doc tool detection.
pub const InferError = error{
    ToolNotInferred,
};

/// Template expansion errors.
pub const TemplateError = error{
    /// A template referenced a placeholder with no value.
    MissingTemplateValue,
    /// Template argv must contain at least one element.
    EmptyTemplate,
};

/// Generation errors for unsupported tool configs.
pub const GenerateError = error{
    /// Shell tool requires a repo argv to execute.
    MissingShellArgv,
};

/// Infer the documentation tool to use based on repo contents.
pub fn infer(allocator: types.Allocator, repo_path: []const u8) !types.DocTool {
    if (try exists(allocator, repo_path, "mkdocs.yml") or try exists(allocator, repo_path, "mkdocs.yaml")) {
        return .mkdocs;
    }
    if (try exists(allocator, repo_path, "docs/conf.py") or try exists(allocator, repo_path, "conf.py")) {
        return .sphinx;
    }
    if (try exists(allocator, repo_path, "Doxyfile")) {
        return .doxygen;
    }
    if (try exists(allocator, repo_path, "go.mod")) {
        return .godoc;
    }
    if (try exists(allocator, repo_path, "Cargo.toml")) {
        return .cargo;
    }
    return InferError.ToolNotInferred;
}

/// Generate docs for a repo using the requested tool.
pub fn generate(
    allocator: types.Allocator,
    tool: types.DocTool,
    repo_path: []const u8,
    doc_path: ?[]const u8,
    output_dir: []const u8,
    options: runner.RunOptions,
    templates: ?types.ToolTemplates,
    repo_argv: ?types.Command,
) !void {
    const resolved = try resolveDocPath(allocator, tool, repo_path, doc_path);
    const template = templateForTool(tool, templates);
    switch (tool) {
        .mkdocs => try generateMkdocs(allocator, repo_path, resolved, output_dir, options, template),
        .sphinx => try generateSphinx(allocator, repo_path, resolved.?, output_dir, options, template),
        .doxygen => try generateDoxygen(allocator, repo_path, resolved.?, output_dir, options, template),
        .godoc => try generateGoDoc(allocator, repo_path, resolved, output_dir, options, template),
        .cargo => try generateCargoDoc(allocator, repo_path, resolved, output_dir, options, template),
        .shell => try generateShell(allocator, repo_path, resolved, output_dir, options, repo_argv),
    }
}

fn generateMkdocs(
    allocator: types.Allocator,
    repo_path: []const u8,
    doc_path: ?[]const u8,
    output_dir: []const u8,
    options: runner.RunOptions,
    template: ?types.ToolTemplate,
) !void {
    if (template) |tpl| {
        var doc_abs: ?[]const u8 = null;
        if (doc_path) |path| {
            doc_abs = try std.fs.path.join(allocator, &.{ repo_path, path });
            defer allocator.free(doc_abs.?);
        }
        try runTemplate(allocator, tpl, .{
            .repo_path = repo_path,
            .output_dir = output_dir,
            .doc_path = doc_path,
            .doc_abs = doc_abs,
            .config_path = null,
        }, repo_path, options);
        return;
    }
    var result = try runner.runChecked(allocator, &.{ "mkdocs", "build", "--clean", "-d", output_dir }, repo_path, options);
    result.deinit();
}

fn generateSphinx(
    allocator: types.Allocator,
    repo_path: []const u8,
    source_rel: []const u8,
    output_dir: []const u8,
    options: runner.RunOptions,
    template: ?types.ToolTemplate,
) !void {
    const source_path = try std.fs.path.join(allocator, &.{ repo_path, source_rel });
    defer allocator.free(source_path);
    if (template) |tpl| {
        try runTemplate(allocator, tpl, .{
            .repo_path = repo_path,
            .output_dir = output_dir,
            .doc_path = source_rel,
            .doc_abs = source_path,
            .config_path = null,
        }, repo_path, options);
        return;
    }
    var result = try runner.runChecked(allocator, &.{ "sphinx-build", "-b", "html", source_path, output_dir }, repo_path, options);
    result.deinit();
}

fn generateDoxygen(
    allocator: types.Allocator,
    repo_path: []const u8,
    doxy_rel: []const u8,
    output_dir: []const u8,
    options: runner.RunOptions,
    template: ?types.ToolTemplate,
) !void {
    const doxy_path = try std.fs.path.join(allocator, &.{ repo_path, doxy_rel });
    defer allocator.free(doxy_path);

    const temp_path = try std.fs.path.join(allocator, &.{ output_dir, "Doxyfile.docforge" });
    defer allocator.free(temp_path);

    const contents = try std.fs.cwd().readFileAlloc(allocator, doxy_path, 2 * 1024 * 1024);
    defer allocator.free(contents);

    var file = try std.fs.cwd().createFile(temp_path, .{ .truncate = true });
    defer file.close();
    var buffer: [1024]u8 = undefined;
    var writer = file.writer(&buffer);
    try writer.interface.writeAll(contents);
    try writer.interface.writeAll("\nOUTPUT_DIRECTORY = ");
    try writer.interface.writeAll(output_dir);
    try writer.interface.writeAll("\nGENERATE_HTML = YES\nHTML_OUTPUT = .\n");
    try writer.interface.flush();

    if (template) |tpl| {
        try runTemplate(allocator, tpl, .{
            .repo_path = repo_path,
            .output_dir = output_dir,
            .doc_path = doxy_rel,
            .doc_abs = doxy_path,
            .config_path = temp_path,
        }, repo_path, options);
        return;
    }
    var result = try runner.runChecked(allocator, &.{ "doxygen", temp_path }, repo_path, options);
    result.deinit();
}

fn generateGoDoc(
    allocator: types.Allocator,
    repo_path: []const u8,
    doc_path: ?[]const u8,
    output_dir: []const u8,
    options: runner.RunOptions,
    template: ?types.ToolTemplate,
) !void {
    if (template) |tpl| {
        var doc_abs: ?[]const u8 = null;
        if (doc_path) |path| {
            doc_abs = try std.fs.path.join(allocator, &.{ repo_path, path });
            defer allocator.free(doc_abs.?);
        }
        try runTemplate(allocator, tpl, .{
            .repo_path = repo_path,
            .output_dir = output_dir,
            .doc_path = doc_path,
            .doc_abs = doc_abs,
            .config_path = null,
        }, repo_path, options);
        return;
    }
    var list_result = try runner.runChecked(allocator, &.{ "go", "list", "./..." }, repo_path, options);
    defer list_result.deinit();

    var packages = std.mem.splitScalar(u8, std.mem.trim(u8, list_result.stdout, " \n\r\t"), '\n');

    var index = std.ArrayList(u8).empty;
    defer index.deinit(allocator);
    try index.appendSlice(allocator, "<html><head><meta charset=\"utf-8\"></head><body><h1>Packages</h1><ul>");

    while (packages.next()) |pkg| {
        if (pkg.len == 0) continue;
        const pkg_path = try packagePath(allocator, pkg);
        defer allocator.free(pkg_path);
        const pkg_dir = try std.fs.path.join(allocator, &.{ output_dir, pkg_path });
        defer allocator.free(pkg_dir);
        try fsutils.ensureDir(pkg_dir);

        var doc_result = try runner.runChecked(allocator, &.{ "go", "doc", "-all", pkg }, repo_path, options);
        defer doc_result.deinit();

        const doc_file_path = try std.fs.path.join(allocator, &.{ pkg_dir, "index.html" });
        defer allocator.free(doc_file_path);

        var file = try std.fs.cwd().createFile(doc_file_path, .{ .truncate = true });
        defer file.close();
        var buffer: [2048]u8 = undefined;
        var writer = file.writer(&buffer);
        try writer.interface.writeAll("<html><head><meta charset=\"utf-8\"></head><body><pre>");
        try writeEscaped(&writer.interface, doc_result.stdout);
        try writer.interface.writeAll("</pre></body></html>");
        try writer.interface.flush();

        try index.appendSlice(allocator, "<li><a href=\"");
        try index.appendSlice(allocator, pkg);
        try index.appendSlice(allocator, "/\">");
        try index.appendSlice(allocator, pkg);
        try index.appendSlice(allocator, "</a></li>");
    }

    try index.appendSlice(allocator, "</ul></body></html>");
    const index_path = try std.fs.path.join(allocator, &.{ output_dir, "index.html" });
    defer allocator.free(index_path);
    try fsutils.writeFile(index_path, index.items);
}

fn generateCargoDoc(
    allocator: types.Allocator,
    repo_path: []const u8,
    doc_path: ?[]const u8,
    output_dir: []const u8,
    options: runner.RunOptions,
    template: ?types.ToolTemplate,
) !void {
    if (template) |tpl| {
        var doc_abs: ?[]const u8 = null;
        if (doc_path) |path| {
            doc_abs = try std.fs.path.join(allocator, &.{ repo_path, path });
            defer allocator.free(doc_abs.?);
        }
        try runTemplate(allocator, tpl, .{
            .repo_path = repo_path,
            .output_dir = output_dir,
            .doc_path = doc_path,
            .doc_abs = doc_abs,
            .config_path = null,
        }, repo_path, options);
        return;
    }

    const target_dir = try std.fs.path.join(allocator, &.{ output_dir, ".docforge-cargo" });
    defer allocator.free(target_dir);
    try fsutils.ensureEmptyDir(target_dir);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "cargo");
    try argv.append(allocator, "doc");
    try argv.append(allocator, "--no-deps");
    if (doc_path) |path| {
        const manifest_path = try std.fs.path.join(allocator, &.{ repo_path, path });
        defer allocator.free(manifest_path);
        try argv.append(allocator, "--manifest-path");
        try argv.append(allocator, manifest_path);
    }
    try argv.append(allocator, "--target-dir");
    try argv.append(allocator, target_dir);

    var result = try runner.runChecked(allocator, argv.items, repo_path, options);
    result.deinit();

    const doc_root = try std.fs.path.join(allocator, &.{ target_dir, "doc" });
    defer allocator.free(doc_root);
    try fsutils.copyDir(allocator, doc_root, output_dir);

    if (fsutils.dirExists(target_dir)) {
        try std.fs.cwd().deleteTree(target_dir);
    }
}

fn generateShell(
    allocator: types.Allocator,
    repo_path: []const u8,
    doc_path: ?[]const u8,
    output_dir: []const u8,
    options: runner.RunOptions,
    repo_argv: ?types.Command,
) !void {
    const argv = repo_argv orelse return GenerateError.MissingShellArgv;
    var doc_abs: ?[]const u8 = null;
    if (doc_path) |path| {
        doc_abs = try std.fs.path.join(allocator, &.{ repo_path, path });
        defer allocator.free(doc_abs.?);
    }
    const tpl = types.ToolTemplate{ .argv = argv };
    try runTemplate(allocator, tpl, .{
        .repo_path = repo_path,
        .output_dir = output_dir,
        .doc_path = doc_path,
        .doc_abs = doc_abs,
        .config_path = null,
    }, repo_path, options);
}

/// Resolve the effective documentation path for a tool.
pub fn resolveDocPath(allocator: types.Allocator, tool: types.DocTool, repo_path: []const u8, doc_path: ?[]const u8) !?[]const u8 {
    switch (tool) {
        .mkdocs, .godoc, .cargo, .shell => return doc_path,
        .sphinx => return doc_path orelse try inferSphinxPath(allocator, repo_path),
        .doxygen => return doc_path orelse try inferDoxygenPath(allocator, repo_path),
    }
}

const TemplateValues = struct {
    repo_path: []const u8,
    output_dir: []const u8,
    doc_path: ?[]const u8,
    doc_abs: ?[]const u8,
    config_path: ?[]const u8,
};

fn templateForTool(tool: types.DocTool, templates: ?types.ToolTemplates) ?types.ToolTemplate {
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

fn runTemplate(
    allocator: types.Allocator,
    template: types.ToolTemplate,
    values: TemplateValues,
    cwd: ?[]const u8,
    options: runner.RunOptions,
) !void {
    const argv = try expandTemplate(allocator, template, values);
    defer freeTemplateArgv(allocator, argv);
    var result = try runner.runChecked(allocator, argv, cwd, options);
    result.deinit();
}

fn expandTemplate(allocator: types.Allocator, template: types.ToolTemplate, values: TemplateValues) ![]const []const u8 {
    if (template.argv.len == 0) return TemplateError.EmptyTemplate;
    const argv = try allocator.alloc([]const u8, template.argv.len);
    var filled: usize = 0;
    errdefer {
        var idx: usize = 0;
        while (idx < filled) : (idx += 1) {
            allocator.free(argv[idx]);
        }
        allocator.free(argv);
    }
    for (template.argv, 0..) |arg, idx| {
        argv[idx] = try substituteTemplate(allocator, arg, values);
        filled += 1;
    }
    return argv;
}

fn substituteTemplate(allocator: types.Allocator, input: []const u8, values: TemplateValues) ![]const u8 {
    var out: []const u8 = try allocator.dupe(u8, input);
    out = try replaceAllOwned(allocator, out, "{repo_path}", values.repo_path);
    out = try replaceAllOwned(allocator, out, "{output_dir}", values.output_dir);
    out = try replaceOptionalOwned(allocator, out, "{doc_path}", values.doc_path);
    out = try replaceOptionalOwned(allocator, out, "{doc_abs}", values.doc_abs);
    out = try replaceOptionalOwned(allocator, out, "{config_path}", values.config_path);
    return out;
}

fn replaceOptional(allocator: types.Allocator, input: []const u8, token: []const u8, value: ?[]const u8) ![]const u8 {
    if (value == null) {
        if (std.mem.indexOf(u8, input, token) != null) {
            return TemplateError.MissingTemplateValue;
        }
        return input;
    }
    return replaceAll(allocator, input, token, value.?);
}

fn replaceOptionalOwned(allocator: types.Allocator, input: []const u8, token: []const u8, value: ?[]const u8) ![]const u8 {
    if (value == null) {
        if (std.mem.indexOf(u8, input, token) != null) {
            allocator.free(input);
            return TemplateError.MissingTemplateValue;
        }
        return input;
    }
    return replaceAllOwned(allocator, input, token, value.?);
}

fn replaceAll(allocator: types.Allocator, input: []const u8, token: []const u8, value: []const u8) ![]const u8 {
    const count = std.mem.count(u8, input, token);
    if (count == 0) return allocator.dupe(u8, input);

    const new_len = input.len + count * value.len - count * token.len;
    var out = try allocator.alloc(u8, new_len);
    var in_index: usize = 0;
    var out_index: usize = 0;

    while (std.mem.indexOfPos(u8, input, in_index, token)) |pos| {
        const segment = input[in_index..pos];
        std.mem.copyForwards(u8, out[out_index..][0..segment.len], segment);
        out_index += segment.len;
        std.mem.copyForwards(u8, out[out_index..][0..value.len], value);
        out_index += value.len;
        in_index = pos + token.len;
    }

    const tail = input[in_index..];
    std.mem.copyForwards(u8, out[out_index..][0..tail.len], tail);
    out_index += tail.len;

    return out[0..out_index];
}

fn replaceAllOwned(allocator: types.Allocator, input: []const u8, token: []const u8, value: []const u8) ![]const u8 {
    const output = try replaceAll(allocator, input, token, value);
    allocator.free(input);
    return output;
}

fn inferSphinxPath(allocator: types.Allocator, repo_path: []const u8) ![]const u8 {
    if (try exists(allocator, repo_path, "docs/conf.py")) {
        return "docs";
    }
    return ".";
}

fn inferDoxygenPath(allocator: types.Allocator, repo_path: []const u8) ![]const u8 {
    if (try exists(allocator, repo_path, "Doxyfile")) {
        return "Doxyfile";
    }
    if (try exists(allocator, repo_path, "docs/Doxyfile")) {
        return "docs/Doxyfile";
    }
    return "Doxyfile";
}

fn writeEscaped(writer: *std.Io.Writer, input: []const u8) !void {
    const out = writer;
    for (input) |ch| {
        switch (ch) {
            '&' => try out.writeAll("&amp;"),
            '<' => try out.writeAll("&lt;"),
            '>' => try out.writeAll("&gt;"),
            else => try out.writeByte(ch),
        }
    }
}

fn packagePath(allocator: types.Allocator, pkg: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (pkg) |ch| {
        if (ch == '/') {
            try out.append(allocator, std.fs.path.sep);
        } else {
            try out.append(allocator, ch);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn exists(allocator: types.Allocator, base: []const u8, rel: []const u8) !bool {
    const path = try std.fs.path.join(allocator, &.{ base, rel });
    defer allocator.free(path);
    return fsutils.fileExists(path) or fsutils.dirExists(path);
}

test "infer detects mkdocs" {
    // covers: doc_tool.infer
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "mkdocs.yml", .data = "site_name: test" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    try std.testing.expectEqual(types.DocTool.mkdocs, try infer(std.testing.allocator, path));
}

test "infer detects cargo" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "Cargo.toml", .data = "[package]\nname = \"demo\"\n" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    try std.testing.expectEqual(types.DocTool.cargo, try infer(std.testing.allocator, path));
}

test "template expansion replaces tokens" {
    const allocator = std.testing.allocator;
    const values = TemplateValues{
        .repo_path = "/repo",
        .output_dir = "/out",
        .doc_path = "docs",
        .doc_abs = "/repo/docs",
        .config_path = "/out/Doxyfile.docforge",
    };
    const template = types.ToolTemplate{ .argv = &.{ "tool", "{repo_path}", "{output_dir}", "{doc_path}", "{doc_abs}", "{config_path}" } };
    const argv = try expandTemplate(allocator, template, values);
    defer freeTemplateArgv(allocator, argv);
    try std.testing.expectEqualStrings("/repo", argv[1]);
    try std.testing.expectEqualStrings("/out", argv[2]);
    try std.testing.expectEqualStrings("docs", argv[3]);
    try std.testing.expectEqualStrings("/repo/docs", argv[4]);
    try std.testing.expectEqualStrings("/out/Doxyfile.docforge", argv[5]);
}

test "template expansion errors on missing values" {
    const allocator = std.testing.allocator;
    const values = TemplateValues{
        .repo_path = "/repo",
        .output_dir = "/out",
        .doc_path = null,
        .doc_abs = null,
        .config_path = null,
    };
    const template = types.ToolTemplate{ .argv = &.{ "tool", "{doc_path}" } };
    try std.testing.expectError(TemplateError.MissingTemplateValue, expandTemplate(allocator, template, values));
}

test "template expansion errors on empty argv" {
    const allocator = std.testing.allocator;
    const values = TemplateValues{
        .repo_path = "/repo",
        .output_dir = "/out",
        .doc_path = null,
        .doc_abs = null,
        .config_path = null,
    };
    const template = types.ToolTemplate{ .argv = &.{} };
    try std.testing.expectError(TemplateError.EmptyTemplate, expandTemplate(allocator, template, values));
}

test "generate uses custom template for mkdocs" {
    // covers: doc_tool.generate
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    test_last_len = 0;

    const fake = runner.TestRunner{ .run = struct {
        fn run(alloc: types.Allocator, argv: []const []const u8, _: ?[]const u8, _: runner.RunOptions) anyerror!runner.RunResult {
            clearTestArgs();
            test_last_len = argv.len;
            for (argv, 0..) |arg, idx| {
                if (idx < test_last_argv.len) {
                    test_last_argv[idx] = try std.testing.allocator.dupe(u8, arg);
                }
            }
            const out = try alloc.alloc(u8, 0);
            return runner.RunResult{ .stdout = out, .stderr = out, .term = .{ .Exited = 0 }, .allocator = alloc };
        }
    }.run };

    runner.setTestRunner(fake);
    defer runner.setTestRunner(null);

    const tpl = types.ToolTemplate{ .argv = &.{ "mkdocs", "build", "--config-file", "{repo_path}/mkdocs.yml", "-d", "{output_dir}" } };
    const templates = types.ToolTemplates{ .mkdocs = tpl };

    defer clearTestArgs();
    try generate(allocator, .mkdocs, "/repo", null, "/out", .{}, templates, null);
    try std.testing.expectEqualStrings("--config-file", test_last_argv[2]);
    try std.testing.expectEqualStrings("/repo/mkdocs.yml", test_last_argv[3]);
    try std.testing.expectEqualStrings("/out", test_last_argv[5]);
    try std.testing.expect(test_last_len > 0);
}

test "generate shell errors on missing argv" {
    try std.testing.expectError(GenerateError.MissingShellArgv, generate(
        std.testing.allocator,
        .shell,
        "/repo",
        null,
        "/out",
        .{},
        null,
        null,
    ));
}

test "resolveDocPath infers sphinx docs folder" {
    // covers: doc_tool.resolveDocPath
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("docs");
    try tmp.dir.writeFile(.{ .sub_path = "docs/conf.py", .data = "# conf" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    const resolved = try resolveDocPath(std.testing.allocator, .sphinx, path, null);
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualStrings("docs", resolved.?);
}

var test_last_argv: [10][]u8 = undefined;
var test_last_len: usize = 0;

fn freeTemplateArgv(allocator: types.Allocator, argv: []const []const u8) void {
    for (argv) |arg| {
        allocator.free(arg);
    }
    allocator.free(argv);
}

fn clearTestArgs() void {
    var idx: usize = 0;
    while (idx < test_last_len) : (idx += 1) {
        std.testing.allocator.free(test_last_argv[idx]);
    }
    test_last_len = 0;
}
