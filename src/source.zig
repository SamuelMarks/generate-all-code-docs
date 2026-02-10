const std = @import("std");

/// Source types supported by the tool.
pub const SourceKind = enum {
    /// Local filesystem path.
    path,
    /// Git SSH URL.
    git_ssh,
    /// Git HTTPS URL.
    git_https,
    /// Archive URL (zip or tar).
    archive_url,
};

/// Parsed source with kind and original value.
pub const Source = struct {
    /// Source kind.
    kind: SourceKind,
    /// Original source string.
    value: []const u8,
};

/// Parse a source string into a classified source.
pub fn parse(input: []const u8) Source {
    if (isGitSsh(input)) {
        return .{ .kind = .git_ssh, .value = input };
    }
    if (isHttpUrl(input)) {
        if (isArchiveUrl(input)) {
            return .{ .kind = .archive_url, .value = input };
        }
        if (isGitHttps(input)) {
            return .{ .kind = .git_https, .value = input };
        }
        return .{ .kind = .archive_url, .value = input };
    }
    return .{ .kind = .path, .value = input };
}

/// Check if the input is a git SSH URL.
pub fn isGitSsh(input: []const u8) bool {
    return std.mem.startsWith(u8, input, "git@") or std.mem.startsWith(u8, input, "ssh://");
}

/// Check if the input is an HTTP or HTTPS URL.
pub fn isHttpUrl(input: []const u8) bool {
    return std.mem.startsWith(u8, input, "https://") or std.mem.startsWith(u8, input, "http://");
}

/// Check if the input looks like an archive URL.
pub fn isArchiveUrl(input: []const u8) bool {
    const trimmed = trimQuery(input);
    return hasSuffix(trimmed, ".zip") or hasSuffix(trimmed, ".tar.gz") or hasSuffix(trimmed, ".tgz") or hasSuffix(trimmed, ".tar");
}

/// Check if the input looks like a Git HTTPS URL.
pub fn isGitHttps(input: []const u8) bool {
    return std.mem.containsAtLeast(u8, input, 1, "github.com") or
        std.mem.containsAtLeast(u8, input, 1, "gitlab.com") or
        hasSuffix(input, ".git");
}

fn hasSuffix(input: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, input, suffix);
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

test "parse source kinds" {
    // covers: source.parse
    try std.testing.expectEqual(SourceKind.git_ssh, parse("git@github.com:user/repo.git").kind);
    try std.testing.expectEqual(SourceKind.git_ssh, parse("ssh://git@gitlab.com/user/repo.git").kind);
    try std.testing.expectEqual(SourceKind.archive_url, parse("https://example.com/repo.tar.gz").kind);
    try std.testing.expectEqual(SourceKind.git_https, parse("https://github.com/user/repo.git").kind);
    try std.testing.expectEqual(SourceKind.path, parse("../local/repo").kind);
}

test "source predicate helpers" {
    // covers: source.isGitSsh source.isHttpUrl source.isArchiveUrl source.isGitHttps
    try std.testing.expect(isGitSsh("git@github.com:org/repo.git"));
    try std.testing.expect(isGitSsh("ssh://git@example.com/org/repo.git"));
    try std.testing.expect(isHttpUrl("https://example.com"));
    try std.testing.expect(isHttpUrl("http://example.com"));
    try std.testing.expect(isArchiveUrl("https://example.com/repo.tar.gz?download=1"));
    try std.testing.expect(isArchiveUrl("https://example.com/repo.zip#hash"));
    try std.testing.expect(isGitHttps("https://github.com/org/repo.git"));
    try std.testing.expect(isGitHttps("https://gitlab.com/org/repo"));
}
