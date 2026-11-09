//! Path manipulation, URL query stripping, archive extension detection, and string utilities.

const std = @import("std");
const types = @import("types.zig");
const fsutils = @import("fsutils.zig");

/// Compute a stable hexadecimal cache key from an input string using Wyhash.
///
/// @param allocator Allocator used to duplicate the 16-byte hex string.
/// @param input Arbitrary input slice to hash.
/// @return Allocated hexadecimal string slice owned by caller.
pub fn cacheKey(allocator: types.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8 {
    const hash = std.hash.Wyhash.hash(0, input);
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{x}", .{hash}) catch unreachable;
    return allocator.dupe(u8, text);
}

/// Derive a sanitized repository basename from a source path or URL.
///
/// @param allocator Allocator for the sanitized name buffer.
/// @param source Repository source path or URL string.
/// @return Allocated, filesystem-safe basename owned by caller.
pub fn baseNameFromSource(allocator: types.Allocator, source: []const u8) std.mem.Allocator.Error![]const u8 {
    const trimmed = trimQuery(source);
    const last = lastPathSegment(trimmed);
    const without_ext = stripExtensions(last);
    const candidate = if (without_ext.len == 0) "repo" else without_ext;
    return fsutils.sanitizeName(allocator, candidate);
}

/// Join output directory, site path, and repository subpath into a path.
///
/// @param allocator Allocator used to join path segments.
/// @param output_dir Base output directory.
/// @param site_path Optional site subpath under `output_dir`.
/// @param repo_path Optional repository subpath under `site_path`.
/// @return Joined path slice owned by caller.
pub fn outputPath(
    allocator: types.Allocator,
    output_dir: []const u8,
    site_path: []const u8,
    repo_path: []const u8,
) std.mem.Allocator.Error![]const u8 {
    if (site_path.len == 0 and repo_path.len == 0) {
        return allocator.dupe(u8, output_dir);
    }
    if (site_path.len == 0) {
        return std.Io.Dir.path.join(allocator, &.{ output_dir, repo_path });
    }
    if (repo_path.len == 0) {
        return std.Io.Dir.path.join(allocator, &.{ output_dir, site_path });
    }
    return std.Io.Dir.path.join(allocator, &.{ output_dir, site_path, repo_path });
}

/// Strip URL query (`?`) and fragment (`#`) suffixes at whichever delimiter appears first.
///
/// @param input URL or path string.
/// @return Slice of `input` preceding any `?` or `#` character.
pub fn trimQuery(input: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, input, "?#")) |idx| {
        return input[0..idx];
    }
    return input;
}

/// Extract the final non-empty path segment after `/`, `\`, or `:`.
///
/// @param input Path or URL string (already stripped of query/fragment).
/// @return Final path segment slice.
pub fn lastPathSegment(input: []const u8) []const u8 {
    var end = input.len;
    while (end > 0 and (input[end - 1] == '/' or input[end - 1] == '\x5c' or input[end - 1] == ':')) {
        end -= 1;
    }
    const trimmed = input[0..end];
    if (std.mem.lastIndexOfAny(u8, trimmed, "/\x5c:")) |idx| {
        return trimmed[idx + 1 ..];
    }
    return trimmed;
}

/// Detect the `ArchiveKind` from a URL or filename by inspecting its extension after stripping queries.
///
/// @param input URL or filename string.
/// @return Matching `ArchiveKind`, or `null` if not a recognized archive extension.
pub fn detectArchiveKind(input: []const u8) ?types.ArchiveKind {
    const trimmed = trimQuery(input);
    if (std.mem.endsWith(u8, trimmed, ".tar.gz") or std.mem.endsWith(u8, trimmed, ".tgz")) return .tar_gz;
    if (std.mem.endsWith(u8, trimmed, ".zip")) return .zip;
    if (std.mem.endsWith(u8, trimmed, ".tar")) return .tar;
    return null;
}

/// Strip archive extensions (`.tar.gz`, `.tgz`, `.zip`, `.tar`) from a filename and return the stem.
///
/// @param name Filename string.
/// @return Stem slice without archive extension, or `null` if `name` is not an archive filename.
pub fn archiveBaseName(name: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, name, ".tar.gz")) return name[0 .. name.len - ".tar.gz".len];
    if (std.mem.endsWith(u8, name, ".tgz")) return name[0 .. name.len - ".tgz".len];
    if (std.mem.endsWith(u8, name, ".zip")) return name[0 .. name.len - ".zip".len];
    if (std.mem.endsWith(u8, name, ".tar")) return name[0 .. name.len - ".tar".len];
    return null;
}

/// Strip known archive or `.git` extensions from a repository segment name.
///
/// @param input Segment string.
/// @return Slice with trailing archive or `.git` extension removed.
pub fn stripExtensions(input: []const u8) []const u8 {
    if (archiveBaseName(input)) |base| {
        return base;
    }
    if (std.mem.endsWith(u8, input, ".git")) {
        return input[0 .. input.len - ".git".len];
    }
    return input;
}

/// Normalize a relative subpath by stripping leading `./` or `.`, converting `` to `/`,
/// trimming trailing `/`, and rejecting `..` parent traversal segments.
///
/// @param allocator Allocator for the normalized output slice.
/// @param input Raw relative path string.
/// @return Normalized path slice (empty if input was `.` or empty), or `error.OutputPathCollision` if `..` is present.
pub fn normalizeSubpath(
    allocator: types.Allocator,
    input: []const u8,
) (std.mem.Allocator.Error || error{OutputPathCollision})![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i + 1 < input.len and input[i] == '.' and (input[i + 1] == '/' or input[i + 1] == '\x5c')) {
        i += 2;
    }

    while (i < input.len) : (i += 1) {
        const ch: u8 = if (input[i] == '\x5c') '/' else input[i];
        try out.append(allocator, ch);
    }

    while (out.items.len > 0 and out.items[out.items.len - 1] == '/') {
        out.items.len -= 1;
    }

    if (out.items.len == 1 and out.items[0] == '.') {
        out.items.len = 0;
    }

    var seg_it = std.mem.splitScalar(u8, out.items, '/');
    while (seg_it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) {
            return error.OutputPathCollision;
        }
    }

    return out.toOwnedSlice(allocator);
}

/// Check whether a list of string keys contains a target key.
///
/// @param keys Slice of candidate strings.
/// @param key Target string to find.
/// @return `true` if `key` equals any element in `keys`.
pub fn containsKey(keys: []const []const u8, key: []const u8) bool {
    for (keys) |item| {
        if (std.mem.eql(u8, item, key)) return true;
    }
    return false;
}

/// Replace all occurrences of `token` in `input` with `value`, returning a newly allocated slice.
///
/// @param allocator Allocator for the resulting string.
/// @param input Source string to scan.
/// @param token Non-empty token substring to replace.
/// @param value Replacement string.
/// @return Newly allocated string with all occurrences of `token` replaced.
pub fn replaceAll(
    allocator: types.Allocator,
    input: []const u8,
    token: []const u8,
    value: []const u8,
) std.mem.Allocator.Error![]const u8 {
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

/// Replace all occurrences of `token` in an owned `input` slice and free `input`.
///
/// @param allocator Allocator that owns `input` and allocates the replacement.
/// @param input Owned string slice that will be freed upon success.
/// @param token Non-empty token substring to replace.
/// @param value Replacement string.
/// @return Newly allocated string with all occurrences of `token` replaced.
pub fn replaceAllOwned(
    allocator: types.Allocator,
    input: []const u8,
    token: []const u8,
    value: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const output = try replaceAll(allocator, input, token, value);
    allocator.free(input);
    return output;
}

/// Write HTML-escaped text (`&`, `<`, `>`, `"`, `'`) to a `*std.Io.Writer`.
///
/// @param writer Destination `*std.Io.Writer`.
/// @param input Raw text to escape.
pub fn writeHtmlEscaped(writer: *std.Io.Writer, input: []const u8) std.Io.Writer.Error!void {
    for (input) |ch| {
        switch (ch) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\x27' => try writer.writeAll("&#39;"),
            else => try writer.writeByte(ch),
        }
    }
}

/// Append HTML-escaped text (`&`, `<`, `>`, `"`, `'`) to a `std.ArrayList(u8)`,
/// optionally normalizing backslashes to forward slashes when `normalize_slashes` is true.
///
/// @param out Target byte array list.
/// @param allocator Allocator for `out`.
/// @param input Raw text or path to escape.
/// @param normalize_slashes Whether to convert `\` to `/` before escaping.
pub fn appendHtmlEscaped(
    out: *std.ArrayList(u8),
    allocator: types.Allocator,
    input: []const u8,
    normalize_slashes: bool,
) std.mem.Allocator.Error!void {
    for (input) |raw| {
        const ch: u8 = if (normalize_slashes and raw == '\x5c') '/' else raw;
        switch (ch) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\x27' => try out.appendSlice(allocator, "&#39;"),
            else => try out.append(allocator, ch),
        }
    }
}

test "baseNameFromSource strips extensions and handles empty or root inputs" {
    // covers: paths.baseNameFromSource paths.lastPathSegment paths.stripExtensions
    const allocator = std.testing.allocator;

    const git_name = try baseNameFromSource(allocator, "git@github.com:org/repo.git");
    defer allocator.free(git_name);
    try std.testing.expectEqualStrings("repo", git_name);

    const win_name = try baseNameFromSource(allocator, "C:\x5crepos\x5cmy_repo\x5c");
    defer allocator.free(win_name);
    try std.testing.expectEqualStrings("my_repo", win_name);

    const root_name = try baseNameFromSource(allocator, "///");
    defer allocator.free(root_name);
    try std.testing.expectEqualStrings("repo", root_name);

    const bare_name = try baseNameFromSource(allocator, "plain-repo");
    defer allocator.free(bare_name);
    try std.testing.expectEqualStrings("plain-repo", bare_name);
}

test "detectArchiveKind and archiveBaseName handle all archive extensions" {
    // covers: paths.detectArchiveKind paths.archiveBaseName paths.trimQuery
    try std.testing.expectEqual(@as(?types.ArchiveKind, .tar_gz), detectArchiveKind("https://x/a.tar.gz?dl=1#top"));
    try std.testing.expectEqual(@as(?types.ArchiveKind, .tar_gz), detectArchiveKind("https://x/a.tgz#frag?q=1"));
    try std.testing.expectEqual(@as(?types.ArchiveKind, .zip), detectArchiveKind("https://x/a.zip"));
    try std.testing.expectEqual(@as(?types.ArchiveKind, .tar), detectArchiveKind("https://x/a.tar"));
    try std.testing.expectEqual(@as(?types.ArchiveKind, null), detectArchiveKind("https://x/a.git"));

    try std.testing.expectEqualStrings("a", archiveBaseName("a.tar.gz").?);
    try std.testing.expectEqualStrings("a", archiveBaseName("a.tgz").?);
    try std.testing.expectEqualStrings("a", archiveBaseName("a.zip").?);
    try std.testing.expectEqualStrings("a", archiveBaseName("a.tar").?);
    try std.testing.expect(archiveBaseName("a.txt") == null);
    try std.testing.expectEqualStrings("a.txt", stripExtensions("a.txt"));
    try std.testing.expectEqualStrings("a", stripExtensions("a.tar.gz"));
}

test "cacheKey is deterministic" {
    // covers: paths.cacheKey
    const allocator = std.testing.allocator;
    const key1 = try cacheKey(allocator, "input");
    defer allocator.free(key1);
    const key2 = try cacheKey(allocator, "input");
    defer allocator.free(key2);
    try std.testing.expectEqualStrings(key1, key2);
}

test "outputPath handles all empty and non-empty combinations" {
    // covers: paths.outputPath
    const allocator = std.testing.allocator;

    const both_empty = try outputPath(allocator, "site", "", "");
    defer allocator.free(both_empty);
    try std.testing.expectEqualStrings("site", both_empty);

    const empty_site = try outputPath(allocator, "site", "", "repo");
    defer allocator.free(empty_site);
    try std.testing.expect(std.mem.endsWith(u8, empty_site, "repo"));

    const empty_repo = try outputPath(allocator, "site", "docs", "");
    defer allocator.free(empty_repo);
    try std.testing.expect(std.mem.endsWith(u8, empty_repo, "docs"));

    const full = try outputPath(allocator, "site", "docs", "repo");
    defer allocator.free(full);
    try std.testing.expect(std.mem.endsWith(u8, full, "site/docs/repo") or std.mem.endsWith(u8, full, "site\x5cdocs\x5crepo"));
}

test "normalizeSubpath normalizes slashes and rejects parent traversal" {
    // covers: paths.normalizeSubpath
    const allocator = std.testing.allocator;

    const norm1 = try normalizeSubpath(allocator, "././a\x5cb/c//");
    defer allocator.free(norm1);
    try std.testing.expectEqualStrings("a/b/c", norm1);

    const norm_dot = try normalizeSubpath(allocator, ".");
    defer allocator.free(norm_dot);
    try std.testing.expectEqualStrings("", norm_dot);

    try std.testing.expectError(error.OutputPathCollision, normalizeSubpath(allocator, "../escape"));
    try std.testing.expectError(error.OutputPathCollision, normalizeSubpath(allocator, "a/../b"));
}

test "containsKey and replaceAll utilities" {
    // covers: paths.containsKey paths.replaceAll paths.replaceAllOwned
    const allocator = std.testing.allocator;
    const keys = &[_][]const u8{ "alpha", "beta" };
    try std.testing.expect(containsKey(keys, "beta"));
    try std.testing.expect(!containsKey(keys, "gamma"));

    const unchanged = try replaceAll(allocator, "hello world", "{missing}", "x");
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings("hello world", unchanged);

    var owned: []const u8 = try allocator.dupe(u8, "{a}/{b}/{a}");
    owned = try replaceAllOwned(allocator, owned, "{a}", "one");
    owned = try replaceAllOwned(allocator, owned, "{b}", "two");
    defer allocator.free(owned);
    try std.testing.expectEqualStrings("one/two/one", owned);
}

test "writeHtmlEscaped and appendHtmlEscaped escape all special chars" {
    // covers: paths.writeHtmlEscaped paths.appendHtmlEscaped
    const allocator = std.testing.allocator;
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeHtmlEscaped(&writer, "a&b<c>d\x22e\x27f");
    try std.testing.expectEqualStrings("a&amp;b&lt;c&gt;d&quot;e&#39;f", writer.buffered());

    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);
    try appendHtmlEscaped(&list, allocator, "dir\x5c<\x22\x27&>", true);
    try std.testing.expectEqualStrings("dir/&lt;&quot;&#39;&amp;&gt;", list.items);
}
