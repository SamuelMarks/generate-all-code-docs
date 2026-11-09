//! Root test aggregator importing all `generate-all-code-docs` modules and running end-to-end integration checks.

const std = @import("std");
const types = @import("types.zig");
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
const main_mod = @import("main.zig");

comptime {
    _ = types;
    _ = paths;
    _ = source;
    _ = doc_tool;
    _ = fsutils;
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
    _ = main_mod;
}

test "end-to-end discover -> run -> list -> clean workflow" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);

    try tmp.dir.createDirPath(std.testing.io, "workspace/alpha/.git");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "workspace/alpha/mkdocs.yml", .data = "site_name: alpha\x0a" });

    const ws_root = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "workspace" });
    defer std.testing.allocator.free(ws_root);
    const cfg_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "generate-all-code-docs.json" });
    defer std.testing.allocator.free(cfg_path);
    const out_dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "site" });
    defer std.testing.allocator.free(out_dir);

    var out_buf: [4096]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var err_writer = std.Io.Writer.fixed(&err_buf);

    try app.run(std.testing.allocator, .{
        .mode = .discover,
        .config_path = cfg_path,
        .discover_root = ws_root,
        .discover_absolute = true,
        .init_username = "sam",
        .init_path = "docs",
        .init_output_dir = out_dir,
    }, &out_writer, &err_writer);

    try std.testing.expect(fsutils.fileExists(cfg_path));
}
