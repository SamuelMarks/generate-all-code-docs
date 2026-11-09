//! Core domain types, command templates, error sets, and structured logging primitives.

const std = @import("std");

/// Supported documentation generators.
pub const DocTool = enum {
    /// MkDocs builds static sites from markdown.
    mkdocs,
    /// Sphinx builds HTML from reStructuredText or Markdown.
    sphinx,
    /// Doxygen generates API docs from source code.
    doxygen,
    /// Go doc produces package API documentation.
    godoc,
    /// Cargo doc builds Rust API documentation.
    cargo,
    /// Custom shell command defined per repo.
    shell,
};

/// Reference types for git checkouts.
pub const RefKind = enum {
    /// Semantic or project version that maps to a tag.
    version,
    /// Explicit git tag.
    tag,
    /// Explicit git commit hash.
    commit,
};

/// A reference to checkout in a git repository.
pub const RefSpec = struct {
    /// Reference type.
    kind: RefKind,
    /// Reference value.
    value: []const u8,
};

/// Standard exit codes used by the CLI.
pub const ExitCode = enum(u8) {
    /// Successful execution.
    ok = 0,
    /// Input or configuration error.
    usage = 2,
    /// Runtime failure while processing repositories.
    failure = 3,
};

/// Allocator shorthand used across modules.
pub const Allocator = std.mem.Allocator;

/// Command template for running a documentation tool.
pub const ToolTemplate = struct {
    /// Argument vector with placeholder tokens such as `{output_dir}`.
    argv: []const []const u8,
};

/// Argument vector used for hook and shell commands.
pub const Command = []const []const u8;

/// List of command argument vectors.
pub const CommandList = []const Command;

/// Optional per-tool command templates.
pub const ToolTemplates = struct {
    /// Override template for MkDocs.
    mkdocs: ?ToolTemplate = null,
    /// Override template for Sphinx.
    sphinx: ?ToolTemplate = null,
    /// Override template for Doxygen.
    doxygen: ?ToolTemplate = null,
    /// Override template for Go doc.
    godoc: ?ToolTemplate = null,
    /// Override template for Cargo doc.
    cargo: ?ToolTemplate = null,
};

/// Archive kinds supported for downloads.
pub const ArchiveKind = enum {
    /// Zip archive (`.zip`).
    zip,
    /// Uncompressed tar archive (`.tar`).
    tar,
    /// Gzip-compressed tar archive (`.tar.gz` or `.tgz`).
    tar_gz,

    /// Return the canonical file extension for caching this archive kind.
    ///
    /// @param self The archive kind variant.
    /// @return Canonical file extension string including leading dot.
    pub fn canonicalExt(self: ArchiveKind) []const u8 {
        return switch (self) {
            .zip => ".zip",
            .tar => ".tar",
            .tar_gz => ".tar.gz",
        };
    }
};

/// Unified error set for repository processing, command execution, and IO operations.
pub const GenerateAllCodeDocsError = error{
    /// An external subprocess exited with a non-zero status or signal.
    CommandFailed,
    /// A configured pre-build or post-build hook had an empty argument vector.
    EmptyHookCommand,
    /// An archive URL did not match any supported archive extension.
    UnsupportedArchive,
    /// The site output directory does not exist when attempting to deploy.
    OutputDirMissing,
    /// No documentation tool could be inferred from the repository files.
    ToolNotInferred,
    /// A command template referenced an optional placeholder that had no value.
    MissingTemplateValue,
    /// A command template had an empty argument vector.
    EmptyTemplate,
    /// A repository with `doc_tool = "shell"` did not provide an `argv` array.
    MissingShellArgv,
    /// A custom index HTML template did not contain the required `{{entries}}` token.
    MissingEntriesToken,
    /// A referenced `${VAR}` environment variable was not set or was empty.
    MissingEnvVar,
    /// A `${VAR` token in configuration was missing its closing `}`.
    UnterminatedEnvVar,
    /// Two or more repositories resolved to the same output subpath.
    DuplicateOutputSubpath,
    /// A repository output subpath collided with the site root or attempted `..` traversal.
    OutputPathCollision,
} || std.mem.Allocator.Error || std.Io.Dir.OpenError || std.Io.Dir.CreateDirPathError ||
    std.Io.Dir.DeleteTreeError || std.Io.Dir.DeleteFileError || std.Io.Dir.RealPathFileAllocError ||
    std.Io.Dir.ReadFileAllocError || std.Io.Dir.CopyFileError || std.Io.File.OpenError ||
    std.Io.File.Writer.Error || std.Io.Writer.Error || std.process.RunError || std.Thread.SpawnError ||
    std.json.ParseError(std.json.Scanner) || std.Io.Dir.StatFileError;

/// Structured JSON payload for the `init` event.
pub const InitEvent = struct {
    /// Event discriminator (`"init"`).
    event: []const u8 = "init",
    /// Path to the generated configuration file.
    config: []const u8,
    /// Site output directory initialized.
    output_dir: []const u8,
};

/// Structured JSON payload for the `discover` event.
pub const DiscoverEvent = struct {
    /// Event discriminator (`"discover"`).
    event: []const u8 = "discover",
    /// Number of repositories discovered.
    count: usize,
    /// Path to the written configuration file.
    config: []const u8,
};

/// Structured JSON payload for the `clean` event.
pub const CleanEvent = struct {
    /// Event discriminator (`"clean"`).
    event: []const u8 = "clean",
    /// Directory path cleaned or inspected.
    path: []const u8,
    /// Action taken (`"removed"` or `"would-remove"`).
    action: []const u8,
};

/// Structured JSON payload for the `list` event.
pub const ListEvent = struct {
    /// Event discriminator (`"list"`).
    event: []const u8 = "list",
    /// Repository display name.
    name: []const u8,
    /// Tool label.
    tool: []const u8,
    /// Commit or reference label.
    commit: []const u8,
};

/// Structured JSON payload for the `repo` completion event.
pub const RepoOutcomeEvent = struct {
    /// Event discriminator (`"repo"`).
    event: []const u8 = "repo",
    /// Repository display name.
    name: []const u8,
    /// Target output directory.
    output: []const u8,
    /// Build status (`"dry_run"`, `"skipped"`, or `"built"`).
    status: []const u8,
    /// Documentation tool name, if known.
    tool: ?[]const u8,
    /// Whether the documentation tool was auto-inferred.
    tool_inferred: bool,
    /// Materialized source path, if built or skipped.
    source: ?[]const u8,
    /// Checked-out reference value, if applicable.
    ref: ?[]const u8,
    /// Checked-out reference kind, if applicable.
    ref_kind: ?[]const u8,
    /// Short commit hash, if applicable.
    commit: ?[]const u8,
};

/// Structured JSON payload for the `repo-error` event.
pub const RepoErrorEvent = struct {
    /// Event discriminator (`"repo-error"`).
    event: []const u8 = "repo-error",
    /// Repository display name or source.
    name: []const u8,
    /// Configured repository source string.
    source: []const u8,
    /// Zig error name.
    error_name: []const u8,
};

/// Structured JSON payload for the `deploy` start event.
pub const DeployStartEvent = struct {
    /// Event discriminator (`"deploy"`).
    event: []const u8 = "deploy",
    /// Site output directory being deployed.
    output_dir: []const u8,
    /// Target git remote name.
    remote: []const u8,
    /// Target git branch name.
    branch: []const u8,
    /// Whether deploy is running in dry-run mode.
    dry_run: bool,
};

/// Structured JSON payload for the `deploy` status event.
pub const DeployStatusEvent = struct {
    /// Event discriminator (`"deploy"`).
    event: []const u8 = "deploy",
    /// Status string (e.g., `"no-changes"`).
    status: []const u8,
};

/// Strongly-typed tagged union of all structured log events.
pub const LogEvent = union(enum) {
    /// Configuration initialization event.
    init: InitEvent,
    /// Repository discovery completion event.
    discover: DiscoverEvent,
    /// Directory clean event.
    clean: CleanEvent,
    /// Repository list row event.
    list: ListEvent,
    /// Repository build outcome event.
    repo: RepoOutcomeEvent,
    /// Repository build error event.
    repo_error: RepoErrorEvent,
    /// Deployment start event.
    deploy_start: DeployStartEvent,
    /// Deployment status event.
    deploy_status: DeployStatusEvent,
};

/// Write a structured `LogEvent` as JSON if `json` is true, or format human-readable text.
/// Streams directly to `writer` without any hidden heap allocations or `anytype` parameters.
///
/// @param writer Target `*std.Io.Writer` stream.
/// @param json Whether to emit a JSON log line instead of formatted text.
/// @param event Strongly-typed `LogEvent` payload.
pub fn writeLogEvent(
    writer: *std.Io.Writer,
    json: bool,
    event: LogEvent,
) std.Io.Writer.Error!void {
    if (json) {
        switch (event) {
            inline else => |payload| {
                try std.json.Stringify.value(payload, .{}, writer);
            },
        }
        try writer.writeAll("\x0a");
        return;
    }
    switch (event) {
        .init => |e| try writer.print("Wrote {s}\x0a", .{e.config}),
        .discover => |e| try writer.print("Discovered {d} repos -> {s}\x0a", .{ e.count, e.config }),
        .clean => |e| {
            const prefix = if (std.mem.eql(u8, e.action, "would-remove")) "Would remove" else "Removed";
            try writer.print("{s} {s}\x0a", .{ prefix, e.path });
        },
        .list => |e| try writer.print("{s}  {s}  {s}\x0a", .{ e.name, e.tool, e.commit }),
        .repo => |e| {
            if (std.mem.eql(u8, e.status, "dry_run")) {
                try writer.print("DRY-RUN {s} -> {s} (tool={s})\x0a", .{ e.name, e.output, e.tool orelse "auto" });
            } else if (std.mem.eql(u8, e.status, "skipped")) {
                try writer.print("SKIP {s} -> {s}\x0a", .{ e.name, e.output });
            } else {
                try writer.print("OK {s} ({s}) -> {s} [{s}]\x0a", .{ e.name, e.source orelse "-", e.output, e.tool orelse "auto" });
            }
        },
        .repo_error => |e| try writer.print("ERROR {s} ({s}): {s}\x0a", .{ e.name, e.source, e.error_name }),
        .deploy_start => |e| try writer.print("Deploying {s} -> {s}/{s}\x0a", .{ e.output_dir, e.remote, e.branch }),
        .deploy_status => try writer.writeAll("No changes to deploy.\x0a"),
    }
}

test "ArchiveKind canonicalExt returns expected extensions" {
    // covers: types.canonicalExt
    try std.testing.expectEqualStrings(".zip", ArchiveKind.zip.canonicalExt());
    try std.testing.expectEqualStrings(".tar", ArchiveKind.tar.canonicalExt());
    try std.testing.expectEqualStrings(".tar.gz", ArchiveKind.tar_gz.canonicalExt());
}

test "writeLogEvent emits json and text for all event variants" {
    // covers: types.writeLogEvent
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeLogEvent(&writer, true, .{ .init = .{ .config = "c.json", .output_dir = "site" } });
    try std.testing.expect(std.mem.containsAtLeast(u8, writer.buffered(), 1, "\x22event\x22:\x22init\x22"));

    var text_buf: [2048]u8 = undefined;
    var text_writer = std.Io.Writer.fixed(&text_buf);
    try writeLogEvent(&text_writer, false, .{ .init = .{ .config = "c.json", .output_dir = "site" } });
    try writeLogEvent(&text_writer, false, .{ .discover = .{ .count = 2, .config = "c.json" } });
    try writeLogEvent(&text_writer, false, .{ .clean = .{ .path = "site", .action = "would-remove" } });
    try writeLogEvent(&text_writer, false, .{ .clean = .{ .path = "site", .action = "removed" } });
    try writeLogEvent(&text_writer, false, .{ .list = .{ .name = "r", .tool = "mkdocs", .commit = "abc" } });
    try writeLogEvent(&text_writer, false, .{ .repo = .{ .name = "r", .output = "o", .status = "dry_run", .tool = null, .tool_inferred = false, .source = null, .ref = null, .ref_kind = null, .commit = null } });
    try writeLogEvent(&text_writer, false, .{ .repo = .{ .name = "r", .output = "o", .status = "skipped", .tool = "mkdocs", .tool_inferred = false, .source = "s", .ref = null, .ref_kind = null, .commit = null } });
    try writeLogEvent(&text_writer, false, .{ .repo = .{ .name = "r", .output = "o", .status = "built", .tool = "mkdocs", .tool_inferred = false, .source = "s", .ref = null, .ref_kind = null, .commit = null } });
    try writeLogEvent(&text_writer, false, .{ .repo_error = .{ .name = "r", .source = "s", .error_name = "Err" } });
    try writeLogEvent(&text_writer, false, .{ .deploy_start = .{ .output_dir = "site", .remote = "origin", .branch = "gh-pages", .dry_run = false } });
    try writeLogEvent(&text_writer, false, .{ .deploy_status = .{ .status = "no-changes" } });
    try std.testing.expect(std.mem.containsAtLeast(u8, text_writer.buffered(), 1, "No changes to deploy.\x0a"));
}
