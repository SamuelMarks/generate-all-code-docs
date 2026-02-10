const std = @import("std");
const types = @import("types.zig");
const fsutils = @import("fsutils.zig");

/// Compute a stable cache key from an input string.
pub fn cacheKey(allocator: types.Allocator, input: []const u8) ![]const u8 {
    const hash = std.hash.Wyhash.hash(0, input);
    var buf: [16]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{x}", .{hash});
    return allocator.dupe(u8, text);
}

/// Derive a basename for a repo from a source string.
pub fn baseNameFromSource(allocator: types.Allocator, source: []const u8) ![]const u8 {
    const trimmed = trimQuery(source);
    const last = lastPathSegment(trimmed);
    const without_ext = stripExtensions(last);
    return fsutils.sanitizeName(allocator, without_ext);
}

/// Join output directory, site path, and repo path.
pub fn outputPath(allocator: types.Allocator, output_dir: []const u8, site_path: []const u8, repo_path: []const u8) ![]const u8 {
    if (site_path.len == 0) {
        return std.fs.path.join(allocator, &.{ output_dir, repo_path });
    }
    if (repo_path.len == 0) {
        return std.fs.path.join(allocator, &.{ output_dir, site_path });
    }
    return std.fs.path.join(allocator, &.{ output_dir, site_path, repo_path });
}

fn trimQuery(input: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, input, '?')) |idx| {
        return input[0..idx];
    }
    if (std.mem.indexOfScalar(u8, input, '#')) |idx| {
        return input[0..idx];
    }
    return input;
}

fn lastPathSegment(input: []const u8) []const u8 {
    var end = input.len;
    while (end > 0 and (input[end - 1] == '/' or input[end - 1] == ':')) {
        end -= 1;
    }
    const trimmed = input[0..end];
    if (std.mem.lastIndexOfAny(u8, trimmed, "/:")) |idx| {
        if (idx + 1 < trimmed.len) {
            return trimmed[idx + 1 ..];
        }
    }
    return trimmed;
}

fn stripExtensions(input: []const u8) []const u8 {
    if (std.mem.endsWith(u8, input, ".tar.gz")) {
        return input[0 .. input.len - ".tar.gz".len];
    }
    if (std.mem.endsWith(u8, input, ".tgz")) {
        return input[0 .. input.len - ".tgz".len];
    }
    if (std.mem.endsWith(u8, input, ".zip")) {
        return input[0 .. input.len - ".zip".len];
    }
    if (std.mem.endsWith(u8, input, ".tar")) {
        return input[0 .. input.len - ".tar".len];
    }
    if (std.mem.endsWith(u8, input, ".git")) {
        return input[0 .. input.len - ".git".len];
    }
    return input;
}

test "base name strips extensions" {
    // covers: paths.baseNameFromSource
    const allocator = std.testing.allocator;
    const name = try baseNameFromSource(allocator, "git@github.com:org/repo.git");
    defer allocator.free(name);
    try std.testing.expectEqualStrings("repo", name);
}

test "cache key is stable" {
    // covers: paths.cacheKey
    const allocator = std.testing.allocator;
    const key1 = try cacheKey(allocator, "input");
    defer allocator.free(key1);
    const key2 = try cacheKey(allocator, "input");
    defer allocator.free(key2);
    try std.testing.expectEqualStrings(key1, key2);
}
