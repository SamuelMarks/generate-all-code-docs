const std = @import("std");
const types = @import("types.zig");

/// Runner options for external commands.
pub const RunOptions = struct {
    /// Enable verbose logging.
    verbose: bool = false,
    /// Optional log file for command output.
    log_file: ?std.fs.File = null,
    /// Emit JSON logs for command invocations.
    json: bool = false,
    /// Skip SSL verification for git and curl.
    insecure: bool = false,
    /// Optional mutex to serialize log output.
    log_mutex: ?*std.Thread.Mutex = null,
};

/// Captured command output.
pub const RunResult = struct {
    /// Standard output bytes.
    stdout: []u8,
    /// Standard error bytes.
    stderr: []u8,
    /// Process termination information.
    term: std.process.Child.Term,
    /// Allocator used for output buffers.
    allocator: types.Allocator,

    /// Release captured output buffers.
    pub fn deinit(self: *RunResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

/// Test runner callback signature.
pub const TestRunner = struct {
    /// Function invoked instead of the real runner during tests.
    run: *const fn (types.Allocator, []const []const u8, ?[]const u8, RunOptions) anyerror!RunResult,
};

var test_runner: ?TestRunner = null;
var test_called: bool = false;

/// Install a test runner implementation.
pub fn setTestRunner(runner: ?TestRunner) void {
    test_runner = runner;
}

/// Run a command and capture its output.
pub fn run(allocator: types.Allocator, argv: []const []const u8, cwd: ?[]const u8, options: RunOptions) !RunResult {
    if (options.verbose) {
        if (options.log_file) |file| {
            const maybe_mutex = options.log_mutex;
            if (maybe_mutex) |mutex| mutex.lock();
            defer if (maybe_mutex) |mutex| mutex.unlock();

            var buffer: [1024]u8 = undefined;
            var writer = file.writer(&buffer);
            if (options.json) {
                const log = CommandLog{ .event = "command", .argv = argv };
                try std.json.Stringify.value(log, .{}, &writer.interface);
                try writer.interface.writeAll("\n");
            } else {
                try writer.interface.writeAll("run:");
                for (argv) |arg| {
                    try writer.interface.writeAll(" ");
                    try writer.interface.writeAll(arg);
                }
                try writer.interface.writeAll("\n");
            }
            try writer.interface.flush();
        }
    }

    if (@import("builtin").is_test) {
        if (test_runner) |runner| {
            return runner.run(allocator, argv, cwd, options);
        }
    }

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = 10 * 1024 * 1024,
    });

    return RunResult{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = result.term,
        .allocator = allocator,
    };
}

const CommandLog = struct {
    event: []const u8,
    argv: []const []const u8,
};

/// Run a command and require a successful exit code.
pub fn runChecked(allocator: types.Allocator, argv: []const []const u8, cwd: ?[]const u8, options: RunOptions) !RunResult {
    var result = try run(allocator, argv, cwd, options);
    if (result.term != .Exited or result.term.Exited != 0) {
        result.deinit();
        return error.CommandFailed;
    }
    return result;
}

test "runner uses test runner" {
    // covers: runner.setTestRunner runner.run runner.deinit
    const allocator = std.testing.allocator;
    test_called = false;

    const fake = TestRunner{ .run = struct {
        fn run(alloc: types.Allocator, argv: []const []const u8, _: ?[]const u8, _: RunOptions) anyerror!RunResult {
            _ = argv;
            test_called = true;
            const out = try alloc.alloc(u8, 0);
            return RunResult{ .stdout = out, .stderr = out, .term = .{ .Exited = 0 }, .allocator = alloc };
        }
    }.run };

    setTestRunner(fake);
    defer setTestRunner(null);

    var result = try run(allocator, &.{"echo"}, null, .{});
    defer result.deinit();
    try std.testing.expect(test_called);
}

test "runner emits json log when enabled" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile("log.json", .{ .truncate = true, .read = true });
    defer file.close();

    const fake = TestRunner{ .run = struct {
        fn run(alloc: types.Allocator, _: []const []const u8, _: ?[]const u8, _: RunOptions) anyerror!RunResult {
            const out = try alloc.alloc(u8, 0);
            return RunResult{ .stdout = out, .stderr = out, .term = .{ .Exited = 0 }, .allocator = alloc };
        }
    }.run };
    setTestRunner(fake);
    defer setTestRunner(null);

    var result = try run(std.testing.allocator, &.{ "git", "status" }, null, .{
        .verbose = true,
        .json = true,
        .log_file = file,
    });
    defer result.deinit();

    const data = try tmp.dir.readFileAlloc(std.testing.allocator, "log.json", 4096);
    defer std.testing.allocator.free(data);
    try std.testing.expect(std.mem.containsAtLeast(u8, data, 1, "\"event\":\"command\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, data, 1, "\"argv\""));
}

test "runChecked returns error on non-zero exit" {
    // covers: runner.runChecked
    const fake = TestRunner{ .run = struct {
        fn run(alloc: types.Allocator, _: []const []const u8, _: ?[]const u8, _: RunOptions) anyerror!RunResult {
            const out = try alloc.alloc(u8, 0);
            return RunResult{ .stdout = out, .stderr = out, .term = .{ .Exited = 1 }, .allocator = alloc };
        }
    }.run };

    setTestRunner(fake);
    defer setTestRunner(null);

    try std.testing.expectError(error.CommandFailed, runChecked(std.testing.allocator, &.{ "false" }, null, .{}));
}
