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
