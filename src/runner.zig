//! External subprocess execution, output capture, verbose logging, and thread-safe test mocking.

const std = @import("std");
const types = @import("types.zig");
const fsutils = @import("fsutils.zig");

/// Runner options for external commands.
pub const RunOptions = struct {
    /// Enable verbose logging.
    verbose: bool = false,
    /// Optional log file for command output.
    log_file: ?std.Io.File = null,
    /// Emit JSON logs for command invocations.
    json: bool = false,
    /// Skip SSL verification for git and curl.
    insecure: bool = false,
    /// Optional mutex to serialize log output across worker threads.
    log_mutex: ?*std.Io.Mutex = null,
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
    ///
    /// @param self Pointer to the `RunResult` to deinitialize.
    pub fn deinit(self: *RunResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

/// Test runner callback signature with a concrete error set (`types.GenerateAllCodeDocsError`).
pub const TestRunner = struct {
    /// Function invoked instead of spawning an OS process during tests.
    run: *const fn (types.Allocator, []const []const u8, ?[]const u8, RunOptions) types.GenerateAllCodeDocsError!RunResult,
};

/// Global test runner override protected by `test_runner_mutex`.
var test_runner: ?TestRunner = null;
/// Mutex protecting access to `test_runner` across parallel worker threads.
var test_runner_mutex: std.Io.Mutex = .init;

/// Install or clear a test runner implementation in a thread-safe manner.
///
/// @param runner Optional `TestRunner` callback to install, or `null` to restore real process execution.
pub fn setTestRunner(runner: ?TestRunner) void {
    const io = fsutils.defaultIo();
    test_runner_mutex.lockUncancelable(io);
    defer test_runner_mutex.unlock(io);
    test_runner = runner;
}

/// Read the currently installed `TestRunner` under lock.
///
/// @return Active `TestRunner` if installed.
fn getTestRunner() ?TestRunner {
    const io = fsutils.defaultIo();
    test_runner_mutex.lockUncancelable(io);
    defer test_runner_mutex.unlock(io);
    return test_runner;
}

/// Structured JSON payload for verbose command logging.
const CommandLog = struct {
    /// Event discriminator (`"command"`).
    event: []const u8,
    /// Command argument vector executed.
    argv: []const []const u8,
};

/// Run an external command and capture its standard output and error streams.
///
/// @param allocator Allocator for capturing stdout/stderr buffers.
/// @param argv Command argument slice (`argv[0]` is executable).
/// @param cwd Optional working directory path for the child process.
/// @param options Execution and logging options.
/// @return Captured `RunResult` owned by caller.
pub fn run(
    allocator: types.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    options: RunOptions,
) types.GenerateAllCodeDocsError!RunResult {
    const io = fsutils.defaultIo();
    if (options.verbose) {
        if (options.log_file) |file| {
            const maybe_mutex = options.log_mutex;
            if (maybe_mutex) |mutex| mutex.lockUncancelable(io);
            defer if (maybe_mutex) |mutex| mutex.unlock(io);

            var buffer: [1024]u8 = undefined;
            var writer = file.writerStreaming(io, &buffer);
            if (options.json) {
                const log = CommandLog{ .event = "command", .argv = argv };
                try std.json.Stringify.value(log, .{}, &writer.interface);
                try writer.interface.writeAll("\x0a");
            } else {
                try writer.interface.writeAll("run:");
                for (argv) |arg| {
                    try writer.interface.writeAll(" ");
                    try writer.interface.writeAll(arg);
                }
                try writer.interface.writeAll("\x0a");
            }
            try writer.interface.flush();
        }
    }

    if (@import("builtin").is_test) {
        if (getTestRunner()) |installed| {
            return installed.run(allocator, argv, cwd, options);
        }
    }

    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = if (cwd) |dir| .{ .path = dir } else .inherit,
        .stdout_limit = .limited(10 * 1024 * 1024),
        .stderr_limit = .limited(10 * 1024 * 1024),
    });

    return RunResult{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = result.term,
        .allocator = allocator,
    };
}

/// Run an external command and require exit code 0, freeing buffers and returning `error.CommandFailed` otherwise.
///
/// @param allocator Allocator for capturing stdout/stderr buffers.
/// @param argv Command argument slice.
/// @param cwd Optional working directory path.
/// @param options Execution and logging options.
/// @return Captured `RunResult` when exit status is 0.
pub fn runChecked(
    allocator: types.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    options: RunOptions,
) types.GenerateAllCodeDocsError!RunResult {
    var result = try run(allocator, argv, cwd, options);
    if (result.term != .exited or result.term.exited != 0) {
        result.deinit();
        return error.CommandFailed;
    }
    return result;
}

test "runner uses test runner and real process when test runner is null" {
    // covers: runner.setTestRunner runner.getTestRunner runner.run runner.deinit
    const allocator = std.testing.allocator;

    const fake = TestRunner{ .run = struct {
        fn runFn(alloc: types.Allocator, argv: []const []const u8, _: ?[]const u8, _: RunOptions) types.GenerateAllCodeDocsError!RunResult {
            const out = try alloc.dupe(u8, argv[0]);
            const err = try alloc.alloc(u8, 0);
            return RunResult{ .stdout = out, .stderr = err, .term = .{ .exited = 0 }, .allocator = alloc };
        }
    }.runFn };

    setTestRunner(fake);
    defer setTestRunner(null);

    var result = try run(allocator, &.{"echo"}, null, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("echo", result.stdout);
}

test "runner emits json and text verbose logs with mutex locking" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var json_file = try tmp.dir.createFile(std.testing.io, "log.json", .{ .truncate = true, .read = true });
    defer json_file.close(std.testing.io);

    var text_file = try tmp.dir.createFile(std.testing.io, "log.txt", .{ .truncate = true, .read = true });
    defer text_file.close(std.testing.io);

    const fake = TestRunner{ .run = struct {
        fn runFn(alloc: types.Allocator, _: []const []const u8, _: ?[]const u8, _: RunOptions) types.GenerateAllCodeDocsError!RunResult {
            const out = try alloc.alloc(u8, 0);
            const err = try alloc.alloc(u8, 0);
            return RunResult{ .stdout = out, .stderr = err, .term = .{ .exited = 0 }, .allocator = alloc };
        }
    }.runFn };
    setTestRunner(fake);
    defer setTestRunner(null);

    var mutex = std.Io.Mutex.init;

    var json_res = try run(std.testing.allocator, &.{ "git", "status" }, null, .{
        .verbose = true,
        .json = true,
        .log_file = json_file,
        .log_mutex = &mutex,
    });
    defer json_res.deinit();

    var text_res = try run(std.testing.allocator, &.{ "git", "status" }, null, .{
        .verbose = true,
        .json = false,
        .log_file = text_file,
        .log_mutex = &mutex,
    });
    defer text_res.deinit();

    const json_data = try tmp.dir.readFileAlloc(std.testing.io, "log.json", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(json_data);
    try std.testing.expect(std.mem.containsAtLeast(u8, json_data, 1, "\x22event\x22:\x22command\x22"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json_data, 1, "\x22argv\x22:[\x22git\x22,\x22status\x22]"));

    const text_data = try tmp.dir.readFileAlloc(std.testing.io, "log.txt", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(text_data);
    try std.testing.expectEqualStrings("run: git status\x0a", text_data);
}

test "runChecked returns error on non-zero exit or signal termination" {
    // covers: runner.runChecked
    const fake_exit = TestRunner{ .run = struct {
        fn runFn(alloc: types.Allocator, _: []const []const u8, _: ?[]const u8, _: RunOptions) types.GenerateAllCodeDocsError!RunResult {
            const out = try alloc.alloc(u8, 0);
            const err = try alloc.alloc(u8, 0);
            return RunResult{ .stdout = out, .stderr = err, .term = .{ .exited = 1 }, .allocator = alloc };
        }
    }.runFn };

    setTestRunner(fake_exit);
    defer setTestRunner(null);

    try std.testing.expectError(error.CommandFailed, runChecked(std.testing.allocator, &.{"false"}, null, .{}));

    const fake_sig = TestRunner{ .run = struct {
        fn runFn(alloc: types.Allocator, _: []const []const u8, _: ?[]const u8, _: RunOptions) types.GenerateAllCodeDocsError!RunResult {
            const out = try alloc.alloc(u8, 0);
            const err = try alloc.alloc(u8, 0);
            return RunResult{ .stdout = out, .stderr = err, .term = .{ .signal = .KILL }, .allocator = alloc };
        }
    }.runFn };

    setTestRunner(fake_sig);
    try std.testing.expectError(error.CommandFailed, runChecked(std.testing.allocator, &.{"kill"}, null, .{}));
}
