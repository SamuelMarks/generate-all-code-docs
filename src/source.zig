//! Classification of repository source strings into local paths, Git SSH/HTTPS URLs, and archive URLs.

const std = @import("std");
const paths = @import("paths.zig");

/// Source types supported by the tool.
pub const SourceKind = enum {
    /// Local filesystem path.
    path,
    /// Git SSH URL (`git@...` or `ssh://...`).
    git_ssh,
    /// Git HTTP/HTTPS URL.
    git_https,
    /// Archive download URL (`.zip`, `.tar`, `.tar.gz`, `.tgz`).
    archive_url,
};

/// Parsed source with classified kind and original value.
pub const Source = struct {
    /// Source classification kind.
    kind: SourceKind,
    /// Original unparsed source string.
    value: []const u8,
};

/// Parse a repository source string into a classified `Source`.
///
/// @param input Raw repository source path or URL.
/// @return Classified `Source` with `.kind` and `.value`.
pub fn parse(input: []const u8) Source {
    if (isGitSsh(input)) {
        return .{ .kind = .git_ssh, .value = input };
    }
    if (isHttpUrl(input)) {
        if (isArchiveUrl(input)) {
            return .{ .kind = .archive_url, .value = input };
        }
        return .{ .kind = .git_https, .value = input };
    }
    return .{ .kind = .path, .value = input };
}

/// Check if the input string is a Git SSH URL (`git@` or `ssh://`).
///
/// @param input Candidate source string.
/// @return `true` if `input` starts with `git@` or `ssh://`.
pub fn isGitSsh(input: []const u8) bool {
    return std.mem.startsWith(u8, input, "git@") or std.mem.startsWith(u8, input, "ssh://");
}

/// Check if the input string is an HTTP or HTTPS URL.
///
/// @param input Candidate source string.
/// @return `true` if `input` starts with `https://` or `http://`.
pub fn isHttpUrl(input: []const u8) bool {
    return std.mem.startsWith(u8, input, "https://") or std.mem.startsWith(u8, input, "http://");
}

/// Check if the input string has a recognized archive extension (`.zip`, `.tar`, `.tar.gz`, `.tgz`).
///
/// @param input Candidate source string or URL.
/// @return `true` if `paths.detectArchiveKind(input)` is non-null.
pub fn isArchiveUrl(input: []const u8) bool {
    return paths.detectArchiveKind(input) != null;
}

/// Check if the input string is an HTTP/HTTPS URL that is not an archive download URL.
///
/// @param input Candidate source string.
/// @return `true` if `input` is an HTTP(S) Git repository URL.
pub fn isGitHttps(input: []const u8) bool {
    return isHttpUrl(input) and !isArchiveUrl(input);
}

test "parse classifies all source kinds including self-hosted git https" {
    // covers: source.parse
    try std.testing.expectEqual(SourceKind.git_ssh, parse("git@github.com:user/repo.git").kind);
    try std.testing.expectEqual(SourceKind.git_ssh, parse("ssh://git@gitlab.com/user/repo.git").kind);
    try std.testing.expectEqual(SourceKind.archive_url, parse("https://example.com/repo.tar.gz").kind);
    try std.testing.expectEqual(SourceKind.archive_url, parse("https://example.com/repo.zip?token=1#frag").kind);
    try std.testing.expectEqual(SourceKind.git_https, parse("https://github.com/user/repo.git").kind);
    try std.testing.expectEqual(SourceKind.git_https, parse("https://gitea.internal.example.com/org/repo").kind);
    try std.testing.expectEqual(SourceKind.path, parse("../local/repo").kind);
}

test "source predicate helpers cover all branches" {
    // covers: source.isGitSsh source.isHttpUrl source.isArchiveUrl source.isGitHttps
    try std.testing.expect(isGitSsh("git@github.com:org/repo.git"));
    try std.testing.expect(isGitSsh("ssh://git@example.com/org/repo.git"));
    try std.testing.expect(!isGitSsh("https://example.com/org/repo.git"));

    try std.testing.expect(isHttpUrl("https://example.com"));
    try std.testing.expect(isHttpUrl("http://example.com"));
    try std.testing.expect(!isHttpUrl("../local"));

    try std.testing.expect(isArchiveUrl("https://example.com/repo.tar.gz?download=1"));
    try std.testing.expect(isArchiveUrl("https://example.com/repo.zip#hash"));
    try std.testing.expect(!isArchiveUrl("https://example.com/repo.git"));

    try std.testing.expect(isGitHttps("https://github.com/org/repo.git"));
    try std.testing.expect(isGitHttps("https://codeberg.org/org/repo"));
    try std.testing.expect(!isGitHttps("https://example.com/repo.tar.gz"));
    try std.testing.expect(!isGitHttps("../local/repo"));
}
