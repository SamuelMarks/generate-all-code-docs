const std = @import("std");
const types = @import("types.zig");
const fsutils = @import("fsutils.zig");

/// Statistics from HTML injection.
pub const InjectStats = struct {
    scanned: usize = 0,
    updated: usize = 0,
};

const fab_marker = "data-docforge-index-fab";
const max_html_size = 64 * 1024 * 1024;

/// Inject the floating index button into HTML files under a root directory.
pub fn injectIndexFab(allocator: types.Allocator, root_dir: []const u8) !InjectStats {
    var stats = InjectStats{};
    try injectDir(allocator, root_dir, root_dir, &stats);
    return stats;
}

fn injectDir(
    allocator: types.Allocator,
    root_dir: []const u8,
    dir_path: []const u8,
    stats: *InjectStats,
) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        const entry_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
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

fn isHtml(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".html") or std.mem.endsWith(u8, name, ".htm");
}

fn injectFile(allocator: types.Allocator, path: []const u8, rel_path: []const u8) !bool {
    const data = std.fs.cwd().readFileAlloc(allocator, path, max_html_size) catch |err| switch (err) {
        error.FileTooBig => return false,
        else => return err,
    };
    defer allocator.free(data);

    if (std.mem.indexOf(u8, data, fab_marker) != null) return false;

    const index_href = try indexHrefFor(rel_path, allocator);
    defer allocator.free(index_href);
    const injected = try injectHtml(allocator, data, index_href);
    if (injected == null) return false;
    defer allocator.free(injected.?);

    try fsutils.writeFile(path, injected.?);
    return true;
}

fn injectHtml(allocator: types.Allocator, html: []const u8, index_href: []const u8) !?[]const u8 {
    if (std.mem.indexOf(u8, html, fab_marker) != null) return null;

    const snippet = try buildFabSnippet(allocator, index_href);
    defer allocator.free(snippet);

    if (indexOfInsensitive(html, "</body>")) |pos| {
        return try insertAt(allocator, html, snippet, pos);
    }
    if (indexOfInsensitive(html, "</html>")) |pos| {
        return try insertAt(allocator, html, snippet, pos);
    }

    const merged = try std.mem.concat(allocator, u8, &.{ html, snippet });
    return merged;
}

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

fn indexHrefFor(rel_path: []const u8, allocator: types.Allocator) ![]const u8 {
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

fn isSep(ch: u8) bool {
    return ch == '/' or ch == '\\';
}

fn insertAt(allocator: types.Allocator, input: []const u8, insert: []const u8, pos: usize) ![]const u8 {
    const new_len = input.len + insert.len;
    var out = try allocator.alloc(u8, new_len);
    std.mem.copyForwards(u8, out[0..pos], input[0..pos]);
    std.mem.copyForwards(u8, out[pos .. pos + insert.len], insert);
    std.mem.copyForwards(u8, out[pos + insert.len ..], input[pos..]);
    return out;
}

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

fn buildFabSnippet(allocator: types.Allocator, index_href: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "\n<!-- docforge index fab -->\n");
    try out.appendSlice(allocator, fab_style);
    try out.appendSlice(allocator, "\n");
    try out.appendSlice(allocator, "<a class=\"docforge-index-fab\" data-docforge-index-fab href=\"");
    try out.appendSlice(allocator, index_href);
    try out.appendSlice(allocator, "\" aria-label=\"Docs index\" title=\"Docs index\">");
    try out.appendSlice(allocator, fab_icon);
    try out.appendSlice(allocator, "<span class=\"docforge-index-fab__label\">Index</span></a>");
    try out.appendSlice(allocator, fab_script);
    try out.appendSlice(allocator, "\n");

    return out.toOwnedSlice(allocator);
}

const fab_style =
    \\<style>
    \\.docforge-index-fab{position:fixed;right:1.5rem;bottom:1.5rem;z-index:2147483000;display:inline-flex;align-items:center;gap:0.55rem;padding:0.6rem 0.85rem;border-radius:999px;background:#0f172a;color:#fff;text-decoration:none;font:600 0.85rem/1.1 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;box-shadow:0 12px 24px rgba(15,23,42,0.25);border:1px solid rgba(255,255,255,0.2);backdrop-filter:blur(6px);transition:transform .18s ease,box-shadow .18s ease;}
    \\.docforge-index-fab:hover{transform:translateY(-1px);box-shadow:0 14px 26px rgba(15,23,42,0.3);}
    \\.docforge-index-fab:focus-visible{outline:2px solid rgba(15,118,110,0.6);outline-offset:3px;}
    \\.docforge-index-fab__label{max-width:0;opacity:0;overflow:hidden;white-space:nowrap;transition:max-width .2s ease,opacity .2s ease;}
    \\.docforge-index-fab__icon{width:18px;height:18px;display:inline-flex;align-items:center;justify-content:center;}
    \\.docforge-index-fab svg{width:18px;height:18px;display:block;stroke:currentColor;fill:none;stroke-width:2;stroke-linecap:round;stroke-linejoin:round;}
    \\.docforge-index-fab:hover .docforge-index-fab__label,
    \\.docforge-index-fab:focus-visible .docforge-index-fab__label,
    \\.docforge-index-fab[data-open="true"] .docforge-index-fab__label{max-width:140px;opacity:1;}
    \\@media (max-width:540px){.docforge-index-fab{right:1rem;bottom:1rem;}}
    \\@media (prefers-reduced-motion: reduce){.docforge-index-fab,.docforge-index-fab__label{transition:none;}}
    \\</style>
;

const fab_icon =
    \\<span class="docforge-index-fab__icon" aria-hidden="true">
    \\  <svg viewBox="0 0 24 24" role="img" focusable="false">
    \\    <path d="M4 6h16M4 12h16M4 18h10"></path>
    \\  </svg>
    \\</span>
;

const fab_script =
    \\<script>
    \\(function(){
    \\  var fab = document.querySelector('[data-docforge-index-fab]');
    \\  if (!fab) return;
    \\  var hoverable = false;
    \\  try { hoverable = window.matchMedia('(hover: hover)').matches; } catch (e) {}
    \\  if (!hoverable) {
    \\    fab.addEventListener('click', function(e){
    \\      if (!fab.hasAttribute('data-open')) {
    \\        fab.setAttribute('data-open','true');
    \\        e.preventDefault();
    \\        e.stopPropagation();
    \\      }
    \\    });
    \\    document.addEventListener('click', function(e){
    \\      if (!fab.contains(e.target)) {
    \\        fab.removeAttribute('data-open');
    \\      }
    \\    });
    \\  }
    \\})();
    \\</script>
;

test "injects fab before body" {
    const allocator = std.testing.allocator;
    const input = "<html><body><h1>Hi</h1></body></html>";
    const out = try injectHtml(allocator, input, "/docs/index.html");
    defer allocator.free(out.?);
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, fab_marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "</body>") != null);
}

test "skip injection when marker present" {
    const allocator = std.testing.allocator;
    const input = "<html><body><a data-docforge-index-fab href=\"/\">Index</a></body></html>";
    const out = try injectHtml(allocator, input, "/index.html");
    try std.testing.expect(out == null);
}

test "injectIndexFab updates html files" {
    // covers: inject.injectIndexFab
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "index.html", .data = "<html><body>Hi</body></html>" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const stats = try injectIndexFab(std.testing.allocator, root);
    try std.testing.expectEqual(@as(usize, 1), stats.scanned);
    try std.testing.expectEqual(@as(usize, 1), stats.updated);

    const data = try tmp.dir.readFileAlloc(std.testing.allocator, "index.html", 4096);
    defer std.testing.allocator.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, fab_marker) != null);
}
