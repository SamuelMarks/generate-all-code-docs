//! CLI entrypoint and exit code classification for the `generate-all-code-docs` executable.

const std = @import("std");
const types = @import("types.zig");
const args = @import("args.zig");
const config = @import("config.zig");
const app = @import("app.zig");

/// Classify a `GenerateAllCodeDocsError` into the appropriate CLI `ExitCode` (`.usage` for configuration errors, `.failure` for runtime errors).
///
/// @param err Error returned by `app.run`.
/// @return `.usage` for `ConfigError` members, or `.failure` for runtime failures.
pub fn exitCodeForError(err: types.GenerateAllCodeDocsError) types.ExitCode {
    return switch (err) {
        config.ConfigError.MissingEnvVar,
        config.ConfigError.UnterminatedEnvVar,
        config.ConfigError.DuplicateOutputSubpath,
        config.ConfigError.OutputPathCollision,
        => .usage,
        else => .failure,
    };
}

/// CLI entrypoint invoked by the Zig runtime.
///
/// @param init Minimal process initialization context providing `args` and `environ`.
pub fn main(init: std.process.Init.Minimal) types.GenerateAllCodeDocsError!void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.Options.debug_threaded_io.?.environ.process_environ = init.environ;
    const io = std.Options.debug_io;

    const argv = try init.args.toSlice(allocator);
    defer allocator.free(argv);

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buf);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    const parsed = args.parse(argv) catch {
        try args.printUsage(stderr);
        try stderr.flush();
        std.process.exit(@backingInt(types.ExitCode.usage));
    };

    app.run(allocator, parsed, stdout, stderr) catch |err| {
        try stderr.print("error: {s}\x0a", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(@backingInt(exitCodeForError(err)));
    };

    try stdout.flush();
    try stderr.flush();
}

test "exitCodeForError maps ConfigError to usage and runtime errors to failure" {
    // covers: main.exitCodeForError
    try std.testing.expectEqual(types.ExitCode.usage, exitCodeForError(config.ConfigError.MissingEnvVar));
    try std.testing.expectEqual(types.ExitCode.usage, exitCodeForError(config.ConfigError.UnterminatedEnvVar));
    try std.testing.expectEqual(types.ExitCode.usage, exitCodeForError(config.ConfigError.DuplicateOutputSubpath));
    try std.testing.expectEqual(types.ExitCode.usage, exitCodeForError(config.ConfigError.OutputPathCollision));
    try std.testing.expectEqual(types.ExitCode.failure, exitCodeForError(error.CommandFailed));
}
