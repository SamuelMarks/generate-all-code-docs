const std = @import("std");
const types = @import("types.zig");
const args = @import("args.zig");
const app = @import("app.zig");

/// CLI entrypoint.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }
    const allocator = gpa.allocator();

    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    const stdout_file = std.fs.File.stdout();
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    const stderr_file = std.fs.File.stderr();
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = stderr_file.writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const parsed = args.parse(raw_args) catch |err| {
        _ = err;
        try args.printUsage(stderr);
        try stderr.flush();
        std.process.exit(@intFromEnum(types.ExitCode.usage));
    };

    app.run(allocator, parsed, stdout, stderr) catch |err| {
        try stderr.print("error: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(@intFromEnum(types.ExitCode.failure));
    };

    try stdout.flush();
    try stderr.flush();
}
