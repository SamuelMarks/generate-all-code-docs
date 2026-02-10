const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");
const fsutils = @import("fsutils.zig");

/// Entry metadata for the global index page.
pub const RepoEntry = struct {
    /// Display name for the repository.
    name: []const u8,
    /// Output subpath under the site root.
    output_subpath: []const u8,
    /// Original source string.
    source: []const u8,
    /// Documentation tool used to build the site.
    doc_tool: types.DocTool,
    /// Reference kind, if known.
    ref_kind: ?types.RefKind = null,
    /// Reference value, if known.
    ref_value: ?[]const u8 = null,
    /// Short commit hash, if known.
    commit_short: ?[]const u8 = null,

    /// Create an entry by duplicating strings into the provided allocator.
    pub fn init(allocator: types.Allocator, entry: RepoEntry) !RepoEntry {
        return RepoEntry{
            .name = try allocator.dupe(u8, entry.name),
            .output_subpath = try allocator.dupe(u8, entry.output_subpath),
            .source = try allocator.dupe(u8, entry.source),
            .doc_tool = entry.doc_tool,
            .ref_kind = entry.ref_kind,
            .ref_value = if (entry.ref_value) |value| try allocator.dupe(u8, value) else null,
            .commit_short = if (entry.commit_short) |value| try allocator.dupe(u8, value) else null,
        };
    }
};

/// Template rendering errors.
pub const TemplateError = error{
    /// Required template token was missing.
    MissingEntriesToken,
};

/// Render the global index HTML for the site.
pub fn render(allocator: types.Allocator, site: config.Site, entries: []const RepoEntry) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "<!doctype html><html><head><meta charset=\"utf-8\">");
    try out.appendSlice(allocator, "<title>docforge index</title>");
    try out.appendSlice(allocator, "<style>body{font-family:\"Space Grotesk\",\"Avenir Next\",\"Gill Sans\",sans-serif;padding:2.5rem;background:radial-gradient(1200px 600px at 10% -10%,#fde68a 0%,rgba(253,230,138,0) 60%),linear-gradient(135deg,#f8fafc 0%,#f1f5f9 50%,#fef9c3 100%);color:#1f2937}main{max-width:980px;margin:0 auto;background:#ffffffee;padding:2.2rem;border-radius:18px;box-shadow:0 10px 30px rgba(15,23,42,0.12);backdrop-filter:blur(6px)}table{width:100%;border-collapse:collapse;margin-top:1.8rem}th,td{text-align:left;padding:0.65rem;border-bottom:1px solid #e2e8f0}th{font-size:0.78rem;text-transform:uppercase;letter-spacing:0.14em;color:#6b7280}code{background:#f1f5f9;padding:0.12rem 0.35rem;border-radius:6px}a{color:#0f766e;text-decoration:none}a:hover{text-decoration:underline}h1{margin-top:0;font-size:2.1rem;letter-spacing:-0.02em}p.meta{color:#475569}</style>");
    try out.appendSlice(allocator, "</head><body><main>");
    try out.appendSlice(allocator, "<h1>Docforge index</h1>");
    try out.appendSlice(allocator, "<p class=\"meta\">");
    try out.appendSlice(allocator, "Site ");
    try writeEscaped(out.writer(allocator), site.username);
    try out.appendSlice(allocator, ".github.io/");
    try writeEscaped(out.writer(allocator), site.path);
    try out.appendSlice(allocator, "</p>");

    const entries_html = try renderEntries(allocator, entries);
    defer allocator.free(entries_html);
    try out.appendSlice(allocator, entries_html);
    try out.appendSlice(allocator, "</main></body></html>");
    return out.toOwnedSlice(allocator);
}

/// Render the global index HTML using a custom template.
pub fn renderWithTemplate(
    allocator: types.Allocator,
    site: config.Site,
    entries: []const RepoEntry,
    template_path: []const u8,
) ![]const u8 {
    const template = try std.fs.cwd().readFileAlloc(allocator, template_path, 1024 * 1024);
    defer allocator.free(template);

    if (std.mem.indexOf(u8, template, "{{entries}}") == null) {
        return TemplateError.MissingEntriesToken;
    }

    const entries_html = try renderEntries(allocator, entries);
    defer allocator.free(entries_html);

    var output = try replaceAll(allocator, template, "{{entries}}", entries_html);
    errdefer allocator.free(output);
    output = try replaceAllOwned(allocator, output, "{{site_username}}", site.username);
    output = try replaceAllOwned(allocator, output, "{{site_path}}", site.path);

    const site_url = try siteUrl(allocator, site);
    defer allocator.free(site_url);
    output = try replaceAllOwned(allocator, output, "{{site_url}}", site_url);

    return output;
}

/// Write the global index HTML to the site root.
pub fn writeIndex(
    allocator: types.Allocator,
    site_root: []const u8,
    site: config.Site,
    entries: []const RepoEntry,
    template_path: ?[]const u8,
) !void {
    const html = if (template_path) |path|
        try renderWithTemplate(allocator, site, entries, path)
    else
        try render(allocator, site, entries);
    defer allocator.free(html);
    const index_path = try std.fs.path.join(allocator, &.{ site_root, "index.html" });
    defer allocator.free(index_path);
    try fsutils.writeFile(index_path, html);
}

fn searchPath(tool: types.DocTool) ?[]const u8 {
    return switch (tool) {
        .mkdocs => "search/",
        .sphinx, .doxygen => "search.html",
        .godoc, .cargo, .shell => null,
    };
}

fn writeRepoLink(writer: anytype, subpath: []const u8, suffix: []const u8) !void {
    if (subpath.len == 0) {
        try writer.writeAll("./");
        if (suffix.len > 0) {
            try writer.writeAll(suffix);
        }
        return;
    }
    try writeEscapedPath(writer, subpath);
    if (!std.mem.endsWith(u8, subpath, "/")) {
        try writer.writeAll("/");
    }
    if (suffix.len > 0) {
        try writer.writeAll(suffix);
    }
}

fn writeEscaped(writer: anytype, input: []const u8) !void {
    for (input) |ch| {
        switch (ch) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&#39;"),
            else => try writer.writeByte(ch),
        }
    }
}

fn writeEscapedPath(writer: anytype, input: []const u8) !void {
    for (input) |raw| {
        const ch = if (raw == '\\') '/' else raw;
        switch (ch) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&#39;"),
            else => try writer.writeByte(ch),
        }
    }
}

fn renderEntries(allocator: types.Allocator, entries: []const RepoEntry) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    if (entries.len == 0) {
        try out.appendSlice(allocator, "<p>No repositories configured.</p>");
        return out.toOwnedSlice(allocator);
    }

    try out.appendSlice(allocator, "<table><thead><tr>");
    try out.appendSlice(allocator, "<th>Repository</th><th>Tool</th><th>Ref</th><th>Commit</th><th>Source</th><th>Search</th>");
    try out.appendSlice(allocator, "</tr></thead><tbody>");

    for (entries) |entry| {
        try out.appendSlice(allocator, "<tr><td>");
        try out.appendSlice(allocator, "<a href=\"");
        try writeRepoLink(out.writer(allocator), entry.output_subpath, "");
        try out.appendSlice(allocator, "\">");
        try writeEscaped(out.writer(allocator), entry.name);
        try out.appendSlice(allocator, "</a></td><td>");
        try out.appendSlice(allocator, @tagName(entry.doc_tool));
        try out.appendSlice(allocator, "</td><td>");
        if (entry.ref_value) |ref| {
            if (entry.ref_kind) |kind| {
                try out.appendSlice(allocator, @tagName(kind));
                try out.appendSlice(allocator, ":");
            }
            try writeEscaped(out.writer(allocator), ref);
        } else {
            try out.appendSlice(allocator, "-");
        }
        try out.appendSlice(allocator, "</td><td>");
        if (entry.commit_short) |commit| {
            try writeEscaped(out.writer(allocator), commit);
        } else {
            try out.appendSlice(allocator, "-");
        }
        try out.appendSlice(allocator, "</td><td><code>");
        try writeEscaped(out.writer(allocator), entry.source);
        try out.appendSlice(allocator, "</code></td><td>");
        if (searchPath(entry.doc_tool)) |search| {
            try out.appendSlice(allocator, "<a href=\"");
            try writeRepoLink(out.writer(allocator), entry.output_subpath, search);
            try out.appendSlice(allocator, "\">search</a>");
        } else {
            try out.appendSlice(allocator, "-");
        }
        try out.appendSlice(allocator, "</td></tr>");
    }

    try out.appendSlice(allocator, "</tbody></table>");
    return out.toOwnedSlice(allocator);
}

fn siteUrl(allocator: types.Allocator, site: config.Site) ![]const u8 {
    if (site.path.len == 0) {
        return std.fmt.allocPrint(allocator, "{s}.github.io", .{site.username});
    }
    return std.fmt.allocPrint(allocator, "{s}.github.io/{s}", .{ site.username, site.path });
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

test "render includes search links" {
    // covers: index.render
    const allocator = std.testing.allocator;
    const site = config.Site{ .username = "sam", .path = "docs", .output_dir = "site" };
    const entries = [_]RepoEntry{
        .{ .name = "repo", .output_subpath = "repo", .source = "src", .doc_tool = .mkdocs },
        .{ .name = "lib", .output_subpath = "lib", .source = "src2", .doc_tool = .sphinx },
    };

    const html = try render(allocator, site, entries[0..]);
    defer allocator.free(html);
    try std.testing.expect(std.mem.containsAtLeast(u8, html, 1, "search/"));
    try std.testing.expect(std.mem.containsAtLeast(u8, html, 1, "search.html"));
}

test "RepoEntry init duplicates fields" {
    // covers: index.init
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const entry = RepoEntry{
        .name = "repo",
        .output_subpath = "repo",
        .source = "src",
        .doc_tool = .mkdocs,
        .ref_kind = .tag,
        .ref_value = "v1.0.0",
        .commit_short = "abc123",
    };
    const dup = try RepoEntry.init(allocator, entry);
    try std.testing.expectEqualStrings(entry.name, dup.name);
    try std.testing.expectEqualStrings(entry.output_subpath, dup.output_subpath);
    try std.testing.expectEqualStrings(entry.source, dup.source);
    try std.testing.expectEqual(entry.doc_tool, dup.doc_tool);
    try std.testing.expectEqual(entry.ref_kind.?, dup.ref_kind.?);
    try std.testing.expectEqualStrings(entry.ref_value.?, dup.ref_value.?);
    try std.testing.expectEqualStrings(entry.commit_short.?, dup.commit_short.?);
}

test "writeIndex creates file" {
    // covers: index.writeIndex
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const site = config.Site{ .username = "sam", .path = "docs", .output_dir = "site" };
    const entries = [_]RepoEntry{.{ .name = "repo", .output_subpath = "repo", .source = "src", .doc_tool = .mkdocs }};

    try writeIndex(std.testing.allocator, root, site, entries[0..], null);

    const index_path = try std.fs.path.join(std.testing.allocator, &.{ root, "index.html" });
    defer std.testing.allocator.free(index_path);
    try std.testing.expect(fsutils.fileExists(index_path));
}

test "renderWithTemplate injects entries" {
    // covers: index.renderWithTemplate
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const template_path = try std.fs.path.join(std.testing.allocator, &.{ root, "template.html" });
    defer std.testing.allocator.free(template_path);
    try fsutils.writeFile(template_path, "<html><body>{{entries}}</body></html>");

    const site = config.Site{ .username = "sam", .path = "docs", .output_dir = "site" };
    const entries = [_]RepoEntry{.{ .name = "repo", .output_subpath = "repo", .source = "src", .doc_tool = .mkdocs }};

    const html = try renderWithTemplate(std.testing.allocator, site, entries[0..], template_path);
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.containsAtLeast(u8, html, 1, "repo"));
}
