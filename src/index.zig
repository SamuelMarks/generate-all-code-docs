//! Global index HTML generation, search link mapping, and custom HTML template rendering.

const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");
const fsutils = @import("fsutils.zig");
const paths = @import("paths.zig");

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

    /// Create an entry by duplicating all string fields into the provided allocator.
    ///
    /// @param allocator Allocator for duplicating strings.
    /// @param entry Source `RepoEntry` to duplicate.
    /// @return Duplicated `RepoEntry` owned by `allocator`.
    pub fn init(allocator: types.Allocator, entry: RepoEntry) std.mem.Allocator.Error!RepoEntry {
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        const output_subpath = try allocator.dupe(u8, entry.output_subpath);
        errdefer allocator.free(output_subpath);
        const source = try allocator.dupe(u8, entry.source);
        errdefer allocator.free(source);
        const ref_value = if (entry.ref_value) |value| try allocator.dupe(u8, value) else null;
        errdefer if (ref_value) |v| allocator.free(v);
        const commit_short = if (entry.commit_short) |value| try allocator.dupe(u8, value) else null;

        return RepoEntry{
            .name = name,
            .output_subpath = output_subpath,
            .source = source,
            .doc_tool = entry.doc_tool,
            .ref_kind = entry.ref_kind,
            .ref_value = ref_value,
            .commit_short = commit_short,
        };
    }

    /// Free all string fields allocated by `RepoEntry.init`.
    ///
    /// @param self `RepoEntry` instance to release.
    /// @param allocator Allocator that owns the strings.
    pub fn deinit(self: RepoEntry, allocator: types.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.output_subpath);
        allocator.free(self.source);
        if (self.ref_value) |v| allocator.free(v);
        if (self.commit_short) |c| allocator.free(c);
    }
};

/// Template rendering errors.
pub const TemplateError = error{
    /// Required template token `{{entries}}` was missing from the custom template file.
    MissingEntriesToken,
};

/// Render the default global index HTML for the site.
///
/// @param allocator Allocator for the rendered HTML buffer.
/// @param site GitHub Pages site metadata.
/// @param entries Slice of repository entries to display in the table.
/// @return Rendered HTML document owned by caller.
pub fn render(
    allocator: types.Allocator,
    site: config.Site,
    entries: []const RepoEntry,
) std.mem.Allocator.Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "<!doctype html><html><head><meta charset=\x22utf-8\x22>");
    try out.appendSlice(allocator, "<title>generate-all-code-docs index</title>");
    try out.appendSlice(allocator, "<style>body{font-family:\x22Space Grotesk\x22,\x22Avenir Next\x22,\x22Gill Sans\x22,sans-serif;padding:2.5rem;background:radial-gradient(1200px 600px at 10% -10%,#fde68a 0%,rgba(253,230,138,0) 60%),linear-gradient(135deg,#f8fafc 0%,#f1f5f9 50%,#fef9c3 100%);color:#1f2937}main{max-width:980px;margin:0 auto;background:#ffffffee;padding:2.2rem;border-radius:18px;box-shadow:0 10px 30px rgba(15,23,42,0.12);backdrop-filter:blur(6px)}table{width:100%;border-collapse:collapse;margin-top:1.8rem}th,td{text-align:left;padding:0.65rem;border-bottom:1px solid #e2e8f0}th{font-size:0.78rem;text-transform:uppercase;letter-spacing:0.14em;color:#6b7280}code{background:#f1f5f9;padding:0.12rem 0.35rem;border-radius:6px}a{color:#0f766e;text-decoration:none}a:hover{text-decoration:underline}h1{margin-top:0;font-size:2.1rem;letter-spacing:-0.02em}p.meta{color:#475569}</style>");
    try out.appendSlice(allocator, "</head><body><main>");
    try out.appendSlice(allocator, "<h1>generate-all-code-docs index</h1>");
    try out.appendSlice(allocator, "<p class=\x22meta\x22>");
    try out.appendSlice(allocator, "Site ");
    try paths.appendHtmlEscaped(&out, allocator, site.username, false);
    try out.appendSlice(allocator, ".github.io/");
    try paths.appendHtmlEscaped(&out, allocator, site.path, false);
    try out.appendSlice(allocator, "</p>");

    const entries_html = try renderEntries(allocator, entries);
    defer allocator.free(entries_html);
    try out.appendSlice(allocator, entries_html);
    try out.appendSlice(allocator, "</main></body></html>");
    return out.toOwnedSlice(allocator);
}

/// Render the global index HTML using a custom template file containing `{{entries}}`.
///
/// @param allocator Allocator for reading the template and rendering the HTML.
/// @param site GitHub Pages site metadata.
/// @param entries Slice of repository entries to render.
/// @param template_path Path to the custom HTML template file on disk.
/// @return Rendered HTML document owned by caller.
pub fn renderWithTemplate(
    allocator: types.Allocator,
    site: config.Site,
    entries: []const RepoEntry,
    template_path: []const u8,
) types.GenerateAllCodeDocsError![]const u8 {
    const io = fsutils.defaultIo();
    const template = try std.Io.Dir.cwd().readFileAlloc(io, template_path, allocator, .limited(1024 * 1024));
    defer allocator.free(template);

    if (std.mem.indexOf(u8, template, "{{entries}}") == null) {
        return TemplateError.MissingEntriesToken;
    }

    const entries_html = try renderEntries(allocator, entries);
    defer allocator.free(entries_html);

    var output = try paths.replaceAll(allocator, template, "{{entries}}", entries_html);
    errdefer allocator.free(output);
    output = try paths.replaceAllOwned(allocator, output, "{{site_username}}", site.username);
    output = try paths.replaceAllOwned(allocator, output, "{{site_path}}", site.path);

    const site_url = try siteUrl(allocator, site);
    defer allocator.free(site_url);
    output = try paths.replaceAllOwned(allocator, output, "{{site_url}}", site_url);

    return output;
}

/// Write the global `index.html` to `site_root`, using `template_path` if provided.
///
/// @param allocator Allocator for rendering HTML and joining paths.
/// @param site_root Root output directory for the site.
/// @param site GitHub Pages site metadata.
/// @param entries Slice of repository entries.
/// @param template_path Optional custom HTML template path.
pub fn writeIndex(
    allocator: types.Allocator,
    site_root: []const u8,
    site: config.Site,
    entries: []const RepoEntry,
    template_path: ?[]const u8,
) types.GenerateAllCodeDocsError!void {
    const html = if (template_path) |path|
        try renderWithTemplate(allocator, site, entries, path)
    else
        try render(allocator, site, entries);
    defer allocator.free(html);
    const index_path = try std.Io.Dir.path.join(allocator, &.{ site_root, "index.html" });
    defer allocator.free(index_path);
    try fsutils.writeFile(index_path, html);
}

/// Return the relative search page suffix for a given `DocTool`, if supported.
///
/// @param tool Documentation tool enum variant.
/// @return Relative search path (`"search/"` or `"search.html"`), or `null` if the tool has no dedicated search page.
fn searchPath(tool: types.DocTool) ?[]const u8 {
    return switch (tool) {
        .mkdocs => "search/",
        .sphinx, .doxygen => "search.html",
        .godoc, .cargo, .shell => null,
    };
}

/// Append a normalized, HTML-escaped relative link (`subpath/suffix`) to `out`.
///
/// @param out Target byte array list.
/// @param allocator Allocator for `out`.
/// @param subpath Repository output subpath.
/// @param suffix Optional trailing suffix (e.g., `"search/"`).
fn writeRepoLink(
    out: *std.ArrayList(u8),
    allocator: types.Allocator,
    subpath: []const u8,
    suffix: []const u8,
) std.mem.Allocator.Error!void {
    if (subpath.len == 0) {
        try out.appendSlice(allocator, "./");
        if (suffix.len > 0) {
            try out.appendSlice(allocator, suffix);
        }
        return;
    }
    try paths.appendHtmlEscaped(out, allocator, subpath, true);
    if (!std.mem.endsWith(u8, subpath, "/")) {
        try out.appendSlice(allocator, "/");
    }
    if (suffix.len > 0) {
        try out.appendSlice(allocator, suffix);
    }
}

/// Render the HTML `<table>` (or empty message) for `entries`.
///
/// @param allocator Allocator for the rendered HTML fragment.
/// @param entries Slice of repository entries.
/// @return Rendered HTML table fragment owned by caller.
fn renderEntries(allocator: types.Allocator, entries: []const RepoEntry) std.mem.Allocator.Error![]const u8 {
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
        try out.appendSlice(allocator, "<a href=\x22");
        try writeRepoLink(&out, allocator, entry.output_subpath, "");
        try out.appendSlice(allocator, "\x22>");
        try paths.appendHtmlEscaped(&out, allocator, entry.name, false);
        try out.appendSlice(allocator, "</a></td><td>");
        try out.appendSlice(allocator, @tagName(entry.doc_tool));
        try out.appendSlice(allocator, "</td><td>");
        if (entry.ref_value) |ref| {
            if (entry.ref_kind) |kind| {
                try out.appendSlice(allocator, @tagName(kind));
                try out.appendSlice(allocator, ":");
            }
            try paths.appendHtmlEscaped(&out, allocator, ref, false);
        } else {
            try out.appendSlice(allocator, "-");
        }
        try out.appendSlice(allocator, "</td><td>");
        if (entry.commit_short) |commit| {
            try paths.appendHtmlEscaped(&out, allocator, commit, false);
        } else {
            try out.appendSlice(allocator, "-");
        }
        try out.appendSlice(allocator, "</td><td><code>");
        try paths.appendHtmlEscaped(&out, allocator, entry.source, false);
        try out.appendSlice(allocator, "</code></td><td>");
        if (searchPath(entry.doc_tool)) |search| {
            try out.appendSlice(allocator, "<a href=\x22");
            try writeRepoLink(&out, allocator, entry.output_subpath, search);
            try out.appendSlice(allocator, "\x22>search</a>");
        } else {
            try out.appendSlice(allocator, "-");
        }
        try out.appendSlice(allocator, "</td></tr>");
    }

    try out.appendSlice(allocator, "</tbody></table>");
    return out.toOwnedSlice(allocator);
}

/// Format the display URL (`<username>.github.io` or `<username>.github.io/<path>`) for `site`.
///
/// @param allocator Allocator for the formatted URL string.
/// @param site Site configuration.
/// @return Formatted site URL owned by caller.
fn siteUrl(allocator: types.Allocator, site: config.Site) std.mem.Allocator.Error![]const u8 {
    if (site.path.len == 0) {
        return std.fmt.allocPrint(allocator, "{s}.github.io", .{site.username});
    }
    return std.fmt.allocPrint(allocator, "{s}.github.io/{s}", .{ site.username, site.path });
}

test "render handles empty entries, search links, refs, commits, and link edge cases" {
    // covers: index.render index.renderEntries index.searchPath index.writeRepoLink
    const allocator = std.testing.allocator;
    const site = config.Site{ .username = "sam", .path = "docs", .output_dir = "site" };

    const empty_html = try render(allocator, site, &.{});
    defer allocator.free(empty_html);
    try std.testing.expect(std.mem.containsAtLeast(u8, empty_html, 1, "No repositories configured."));

    const entries = [_]RepoEntry{
        .{
            .name = "repo",
            .output_subpath = "",
            .source = "src",
            .doc_tool = .mkdocs,
            .ref_kind = .tag,
            .ref_value = "v1.0",
            .commit_short = "1234567",
        },
        .{
            .name = "lib",
            .output_subpath = "lib/",
            .source = "src2",
            .doc_tool = .sphinx,
        },
        .{
            .name = "go-pkg",
            .output_subpath = "go\x5csub",
            .source = "src3",
            .doc_tool = .godoc,
        },
    };

    const html = try render(allocator, site, entries[0..]);
    defer allocator.free(html);
    try std.testing.expect(std.mem.containsAtLeast(u8, html, 1, "./search/"));
    try std.testing.expect(std.mem.containsAtLeast(u8, html, 1, "lib/search.html"));
    try std.testing.expect(std.mem.containsAtLeast(u8, html, 1, "go/sub/"));
    try std.testing.expect(std.mem.containsAtLeast(u8, html, 1, "tag:v1.0"));
    try std.testing.expect(std.mem.containsAtLeast(u8, html, 1, "1234567"));
}

test "RepoEntry init and deinit duplicate and release fields" {
    // covers: index.init index.deinit
    const allocator = std.testing.allocator;
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
    defer dup.deinit(allocator);
    try std.testing.expectEqualStrings(entry.name, dup.name);
    try std.testing.expectEqualStrings(entry.output_subpath, dup.output_subpath);
    try std.testing.expectEqualStrings(entry.source, dup.source);
    try std.testing.expectEqual(entry.doc_tool, dup.doc_tool);
    try std.testing.expectEqual(entry.ref_kind.?, dup.ref_kind.?);
    try std.testing.expectEqualStrings(entry.ref_value.?, dup.ref_value.?);
    try std.testing.expectEqualStrings(entry.commit_short.?, dup.commit_short.?);

    const minimal = RepoEntry{
        .name = "min",
        .output_subpath = "min",
        .source = "src",
        .doc_tool = .cargo,
    };
    const dup_min = try RepoEntry.init(allocator, minimal);
    defer dup_min.deinit(allocator);
    try std.testing.expect(dup_min.ref_value == null);
    try std.testing.expect(dup_min.commit_short == null);
}

test "writeIndex and renderWithTemplate cover default, custom template, siteUrl, and missing token" {
    // covers: index.writeIndex index.renderWithTemplate index.siteUrl
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const site = config.Site{ .username = "sam", .path = "docs", .output_dir = "site" };
    const root_site = config.Site{ .username = "sam", .path = "", .output_dir = "site" };
    const entries = [_]RepoEntry{.{ .name = "repo", .output_subpath = "repo", .source = "src", .doc_tool = .mkdocs }};

    try writeIndex(std.testing.allocator, root, site, entries[0..], null);

    const index_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ root, "index.html" });
    defer std.testing.allocator.free(index_path);
    try std.testing.expect(fsutils.fileExists(index_path));

    const template_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ root, "template.html" });
    defer std.testing.allocator.free(template_path);
    try fsutils.writeFile(template_path, "<html><body>{{site_url}} {{entries}}</body></html>");

    try writeIndex(std.testing.allocator, root, root_site, entries[0..], template_path);
    const html = try renderWithTemplate(std.testing.allocator, site, entries[0..], template_path);
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.containsAtLeast(u8, html, 1, "sam.github.io/docs"));

    const bad_template = try std.Io.Dir.path.join(std.testing.allocator, &.{ root, "bad.html" });
    defer std.testing.allocator.free(bad_template);
    try fsutils.writeFile(bad_template, "<html>no token</html>");
    try std.testing.expectError(TemplateError.MissingEntriesToken, renderWithTemplate(std.testing.allocator, site, entries[0..], bad_template));
}
