const std = @import("std");
const paths = @import("paths.zig");
const source = @import("source.zig");
const doc_tool = @import("doc_tool.zig");
const fsutils = @import("fsutils.zig");
const archive = @import("archive.zig");
const config = @import("config.zig");
const git = @import("git.zig");
const runner = @import("runner.zig");
const args = @import("args.zig");
const app = @import("app.zig");
const manifest = @import("manifest.zig");
const discover = @import("discover.zig");
const index = @import("index.zig");
const deploy = @import("deploy.zig");
const inject = @import("inject.zig");

// Aggregated tests for shared helpers.
test "output path joins" {
    // covers: paths.outputPath
    const allocator = std.testing.allocator;
    const out = try paths.outputPath(allocator, "site", "docs", "repo");
    defer allocator.free(out);
    try std.testing.expect(std.mem.endsWith(u8, out, "site/docs/repo") or std.mem.endsWith(u8, out, "site\\docs\\repo"));
}

// Ensure source parsing matches expectations.
test "source detection" {
    try std.testing.expectEqual(source.SourceKind.archive_url, source.parse("https://x/y.zip").kind);
}

// Ensure file utils detect existing files.
test "file exists detects" {
    // covers: fsutils.fileExists
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "file.txt", .data = "ok" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "file.txt");
    defer std.testing.allocator.free(path);
    try std.testing.expect(fsutils.fileExists(path));
}

// Import modules to ensure their tests are included.
comptime {
    _ = doc_tool;
    _ = archive;
    _ = config;
    _ = git;
    _ = runner;
    _ = args;
    _ = app;
    _ = manifest;
    _ = discover;
    _ = index;
    _ = deploy;
    _ = inject;
}
