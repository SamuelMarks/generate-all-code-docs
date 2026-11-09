//! Injection of the floating global index action button (`fab`) into generated HTML pages.

const std = @import("std");
const types = @import("types.zig");
const fsutils = @import("fsutils.zig");

/// Statistics from HTML injection.
pub const InjectStats = struct {
    /// Total number of `.html`/`.htm` files scanned.
    scanned: usize = 0,
    /// Number of `.html`/`.htm` files updated with the floating index button.
    updated: usize = 0,
};

/// HTML attribute marker indicating the floating action button has already been injected.
const fab_marker = "data-generate-all-code-docs-index-fab";
/// Maximum HTML file size (64 MiB) to read into memory for injection.
const max_html_size = 64 * 1024 * 1024;

/// Inject the floating index button into all `.html` and `.htm` files under `root_dir`.
///
/// @param allocator Allocator for path joins and HTML buffer rewriting.
/// @param root_dir Site root directory containing generated documentation.
/// @return `InjectStats` with counts of scanned and updated HTML files.
pub fn injectIndexFab(allocator: types.Allocator, root_dir: []const u8) types.GenerateAllCodeDocsError!InjectStats {
    var stats = InjectStats{};
    try injectDir(allocator, root_dir, root_dir, &stats);
    return stats;
}

/// Recursively walk `dir_path` and inject the floating index button into HTML files.
///
/// @param allocator Allocator for temporary path joins and file buffers.
/// @param root_dir Top-level site root directory used to compute relative depth.
/// @param dir_path Current directory being traversed.
/// @param stats Mutable pointer to `InjectStats` counters.
fn injectDir(
    allocator: types.Allocator,
    root_dir: []const u8,
    dir_path: []const u8,
    stats: *InjectStats,
) types.GenerateAllCodeDocsError!void {
    const io = fsutils.defaultIo();
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const entry_path = try std.Io.Dir.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(entry_path);

        switch (entry.kind) {
            .directory => try injectDir(allocator, root_dir, entry_path, stats),
            .file => {
                if (!isHtml(entry.name)) continue;
                stats.scanned += 1;
                const rel_path = relativePath(root_dir, entry_path);
                if (try injectFile(allocator, entry_path, rel_path)) {
                    stats.updated += 1;
                }
            },
            else => continue,
        }
    }
}

/// Check if a filename ends with `.html` or `.htm`.
///
/// @param name Filename string.
/// @return `true` if `name` has an HTML file extension.
fn isHtml(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".html") or std.mem.endsWith(u8, name, ".htm");
}

/// Read an HTML file, inject the floating index button if not already present, and write it back.
///
/// @param allocator Allocator for reading and rewriting the HTML content.
/// @param path Full filesystem path to the HTML file.
/// @param rel_path Path of the HTML file relative to the site root.
/// @return `true` if the file was modified, `false` if skipped.
fn injectFile(allocator: types.Allocator, path: []const u8, rel_path: []const u8) types.GenerateAllCodeDocsError!bool {
    const io = fsutils.defaultIo();
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_html_size));
    defer allocator.free(data);

    const index_href = try indexHrefFor(rel_path, allocator);
    defer allocator.free(index_href);
    const injected = try injectHtml(allocator, data, index_href);
    if (injected == null) return false;
    defer allocator.free(injected.?);

    try fsutils.writeFile(path, injected.?);
    return true;
}

/// Inject the floating button snippet before `</body>`, before `</html>`, or at the end of `html`.
///
/// @param allocator Allocator for the modified HTML buffer.
/// @param html Original HTML content.
/// @param index_href Relative `href` to the root `index.html`.
/// @return Newly allocated HTML string with the snippet injected, or `null` if `fab_marker` is already present.
fn injectHtml(allocator: types.Allocator, html: []const u8, index_href: []const u8) std.mem.Allocator.Error!?[]const u8 {
    if (std.mem.indexOf(u8, html, fab_marker) != null) return null;

    const snippet = try buildFabSnippet(allocator, index_href);
    defer allocator.free(snippet);

    if (indexOfInsensitive(html, "</body>")) |pos| {
        return try insertAt(allocator, html, snippet, pos);
    }
    if (indexOfInsensitive(html, "</html>")) |pos| {
        return try insertAt(allocator, html, snippet, pos);
    }

    return try std.mem.concat(allocator, u8, &.{ html, snippet });
}

/// Compute the slice of `full_path` relative to `root_dir`.
///
/// @param root_dir Base directory prefix.
/// @param full_path Full path under `root_dir`.
/// @return Relative path slice without leading slashes.
fn relativePath(root_dir: []const u8, full_path: []const u8) []const u8 {
    var root = root_dir;
    while (root.len > 0 and isSep(root[root.len - 1])) {
        root = root[0 .. root.len - 1];
    }
    if (std.mem.startsWith(u8, full_path, root)) {
        var rel = full_path[root.len..];
        if (rel.len > 0 and isSep(rel[0])) {
            rel = rel[1..];
        }
        return rel;
    }
    return full_path;
}

/// Compute the relative `../` link from `rel_path` back to the root `index.html`.
///
/// @param rel_path Path of the HTML file relative to the site root.
/// @param allocator Allocator for the resulting `href` string.
/// @return Allocated relative `href` string (e.g., `"index.html"` or `"../../index.html"`).
fn indexHrefFor(rel_path: []const u8, allocator: types.Allocator) std.mem.Allocator.Error![]const u8 {
    var depth: usize = 0;
    for (rel_path) |ch| {
        if (isSep(ch)) depth += 1;
    }
    if (depth == 0) return allocator.dupe(u8, "index.html");

    const prefix_len = depth * 3;
    var out = try allocator.alloc(u8, prefix_len + "index.html".len);
    var i: usize = 0;
    var d: usize = 0;
    while (d < depth) : (d += 1) {
        out[i] = '.';
        out[i + 1] = '.';
        out[i + 2] = '/';
        i += 3;
    }
    std.mem.copyForwards(u8, out[i..], "index.html");
    return out;
}

/// Check if a byte is a forward or backward path separator (`/` or `\`).
///
/// @param ch Character to inspect.
/// @return `true` if `ch` is `/` or `\`.
fn isSep(ch: u8) bool {
    return ch == '/' or ch == '\x5c';
}

/// Insert `insert` into `input` at byte offset `pos`, returning a newly allocated slice.
///
/// @param allocator Allocator for the combined buffer.
/// @param input Original string.
/// @param insert Substring to insert at `pos`.
/// @param pos Byte offset in `input` where `insert` is placed.
/// @return Newly allocated string containing `input[0..pos] ++ insert ++ input[pos..]`.
fn insertAt(allocator: types.Allocator, input: []const u8, insert: []const u8, pos: usize) std.mem.Allocator.Error![]const u8 {
    const new_len = input.len + insert.len;
    var out = try allocator.alloc(u8, new_len);
    std.mem.copyForwards(u8, out[0..pos], input[0..pos]);
    std.mem.copyForwards(u8, out[pos .. pos + insert.len], insert);
    std.mem.copyForwards(u8, out[pos + insert.len ..], input[pos..]);
    return out;
}

/// Find the first ASCII case-insensitive occurrence of `needle` in `haystack`.
///
/// @param haystack Text to search within.
/// @param needle Non-empty target substring.
/// @return Starting byte index of the match, or `null` if not found.
fn indexOfInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            const a = std.ascii.toLower(haystack[i + j]);
            const b = std.ascii.toLower(needle[j]);
            if (a != b) break;
        }
        if (j == needle.len) return i;
    }
    return null;
}

/// Build the complete HTML/CSS/JS snippet for the floating index button pointing to `index_href`.
///
/// @param allocator Allocator for the snippet buffer.
/// @param index_href Relative `href` attribute value.
/// @return Allocated HTML snippet owned by caller.
fn buildFabSnippet(allocator: types.Allocator, index_href: []const u8) std.mem.Allocator.Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "\x0a<!-- generate-all-code-docs index fab -->\x0a");
    try out.appendSlice(allocator, fab_style);
    try out.appendSlice(allocator, "\x0a");
    try out.appendSlice(allocator, "<a class=\x22generate-all-code-docs-index-fab\x22 data-generate-all-code-docs-index-fab href=\x22");
    try out.appendSlice(allocator, index_href);
    try out.appendSlice(allocator, "\x22 aria-label=\x22Docs index\x22 title=\x22Docs index\x22>");
    try out.appendSlice(allocator, fab_icon);
    try out.appendSlice(allocator, "<span class=\x22generate-all-code-docs-index-fab__label\x22>Index</span></a>");
    try out.appendSlice(allocator, fab_script);
    try out.appendSlice(allocator, "\x0a");

    return out.toOwnedSlice(allocator);
}

/// Embedded CSS stylesheet for the floating index button.
const fab_style = "<style>" ++
    ".generate-all-code-docs-index-fab{position:fixed;right:1.5rem;bottom:1.5rem;z-index:2147483000;display:inline-flex;align-items:center;gap:0.55rem;padding:0.6rem 0.85rem;border-radius:999px;background:#0f172a;color:#fff;text-decoration:none;font:600 0.85rem/1.1 -apple-system,BlinkMacSystemFont,\x22Segoe UI\x22,system-ui,sans-serif;box-shadow:0 12px 24px rgba(15,23,42,0.25);border:1px solid rgba(255,255,255,0.2);backdrop-filter:blur(6px);transition:transform .18s ease,box-shadow .18s ease;}" ++
    ".generate-all-code-docs-index-fab:hover{transform:translateY(-1px);box-shadow:0 14px 26px rgba(15,23,42,0.3);}" ++
    ".generate-all-code-docs-index-fab:focus-visible{outline:2px solid rgba(15,118,110,0.6);outline-offset:3px;}" ++
    ".generate-all-code-docs-index-fab__label{max-width:0;opacity:0;overflow:hidden;white-space:nowrap;transition:max-width .2s ease,opacity .2s ease;}" ++
    ".generate-all-code-docs-index-fab__icon{width:18px;height:18px;display:inline-flex;align-items:center;justify-content:center;}" ++
    ".generate-all-code-docs-index-fab svg{width:18px;height:18px;display:block;stroke:currentColor;fill:none;stroke-width:2;stroke-linecap:round;stroke-linejoin:round;}" ++
    ".generate-all-code-docs-index-fab:hover .generate-all-code-docs-index-fab__label," ++
    ".generate-all-code-docs-index-fab:focus-visible .generate-all-code-docs-index-fab__label," ++
    ".generate-all-code-docs-index-fab[data-open=\x22true\x22] .generate-all-code-docs-index-fab__label{max-width:140px;opacity:1;}" ++
    "@media (max-width:540px){.generate-all-code-docs-index-fab{right:1rem;bottom:1rem;}}" ++
    "@media (prefers-reduced-motion: reduce){.generate-all-code-docs-index-fab,.generate-all-code-docs-index-fab__label{transition:none;}}" ++
    "</style>";

/// Embedded SVG icon markup for the floating index button.
const fab_icon = "<span class=\x22generate-all-code-docs-index-fab__icon\x22 aria-hidden=\x22true\x22>" ++
    "<svg viewBox=\x220 0 24 24\x22 role=\x22img\x22 focusable=\x22false\x22>" ++
    "<path d=\x22M4 6h16M4 12h16M4 18h10\x22></path>" ++
    "</svg></span>";

/// Embedded touch-device toggle script for the floating index button.
const fab_script = "<script>(function(){" ++
    "var fab=document.querySelector('[data-generate-all-code-docs-index-fab]');" ++
    "if(!fab)return;" ++
    "var hoverable=false;" ++
    "try{hoverable=window.matchMedia('(hover: hover)').matches;}catch(e){}" ++
    "if(!hoverable){" ++
    "fab.addEventListener('click',function(e){if(!fab.hasAttribute('data-open')){fab.setAttribute('data-open','true');e.preventDefault();e.stopPropagation();}});" ++
    "document.addEventListener('click',function(e){if(!fab.contains(e.target)){fab.removeAttribute('data-open');}});" ++
    "}" ++
    "})();</script>";

test "injectHtml handles body, html fallback, append fallback, case-insensitivity, and existing marker" {
    // covers: inject.injectHtml inject.insertAt inject.indexOfInsensitive inject.buildFabSnippet
    const allocator = std.testing.allocator;

    const with_body = "<html><BODY><h1>Hi</h1></BODY></html>";
    const out1 = (try injectHtml(allocator, with_body, "index.html")).?;
    defer allocator.free(out1);
    try std.testing.expect(std.mem.indexOf(u8, out1, fab_marker) != null);

    const only_html = "<html><h1>Hi</h1></HTML>";
    const out2 = (try injectHtml(allocator, only_html, "index.html")).?;
    defer allocator.free(out2);
    try std.testing.expect(std.mem.indexOf(u8, out2, fab_marker) != null);

    const fragment = "<div>fragment</div>";
    const out3 = (try injectHtml(allocator, fragment, "index.html")).?;
    defer allocator.free(out3);
    try std.testing.expect(std.mem.startsWith(u8, out3, "<div>fragment</div>"));
    try std.testing.expect(std.mem.indexOf(u8, out3, fab_marker) != null);

    const already = try injectHtml(allocator, out1, "index.html");
    try std.testing.expect(already == null);

    try std.testing.expect(indexOfInsensitive("short", "longerneedle") == null);
}

test "relativePath and indexHrefFor handle root slashes and nested depths" {
    // covers: inject.relativePath inject.indexHrefFor inject.isSep
    const allocator = std.testing.allocator;

    try std.testing.expectEqualStrings("a/b/index.html", relativePath("/site/root/", "/site/root/a/b/index.html"));
    try std.testing.expectEqualStrings("/other/index.html", relativePath("/site/root", "/other/index.html"));

    const href0 = try indexHrefFor("index.html", allocator);
    defer allocator.free(href0);
    try std.testing.expectEqualStrings("index.html", href0);

    const href2 = try indexHrefFor("repo/sub/page.html", allocator);
    defer allocator.free(href2);
    try std.testing.expectEqualStrings("../../index.html", href2);
}

test "injectIndexFab recursively updates html and htm files and skips already-injected or non-html files" {
    // covers: inject.injectIndexFab inject.injectDir inject.isHtml inject.injectFile
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "nested");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "index.html", .data = "<html><body>Hi</body></html>" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "nested/page.htm", .data = "<html><body>Sub</body></html>" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "nested/style.css", .data = "body{}" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const stats1 = try injectIndexFab(std.testing.allocator, root);
    try std.testing.expectEqual(@as(usize, 2), stats1.scanned);
    try std.testing.expectEqual(@as(usize, 2), stats1.updated);

    // Second pass should scan 2 and update 0
    const stats2 = try injectIndexFab(std.testing.allocator, root);
    try std.testing.expectEqual(@as(usize, 2), stats2.scanned);
    try std.testing.expectEqual(@as(usize, 0), stats2.updated);

    const sub_data = try tmp.dir.readFileAlloc(std.testing.io, "nested/page.htm", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(sub_data);
    try std.testing.expect(std.mem.indexOf(u8, sub_data, "href=\x22../index.html\x22") != null);
}
