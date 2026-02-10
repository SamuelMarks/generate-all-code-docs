const std = @import("std");

/// CLI modes supported by the tool.
pub const Mode = enum {
    /// Print usage.
    help,
    /// Generate docs from config.
    run,
    /// Write a starter config file.
    init,
    /// Discover repos and write a config file.
    discover,
    /// Deploy site output to GitHub Pages.
    deploy,
    /// Remove cached and output artifacts.
    clean,
    /// List configured repositories and status.
    list,
};

/// Parsed command line arguments.
pub const Args = struct {
    /// Selected mode.
    mode: Mode = .help,
    /// Config path to read or write.
    config_path: []const u8 = "docforge.json",
    /// Dry-run mode.
    dry_run: bool = false,
    /// Verbose logging.
    verbose: bool = false,
    /// Emit JSON logs.
    json: bool = false,
    /// Skip repos that are unchanged.
    incremental: bool = true,
    /// Skip SSL verification for git and curl.
    insecure: bool = false,
    /// Username for init mode.
    init_username: []const u8 = "username",
    /// Site path for init mode.
    init_path: []const u8 = "docs",
    /// Output directory for init mode.
    init_output_dir: []const u8 = "site",
    /// Root directory to scan for discover mode.
    discover_root: []const u8 = ".",
    /// Max depth to scan for discover mode.
    discover_depth: usize = 6,
    /// Use absolute paths for repo sources.
    discover_absolute: bool = false,
    /// Infer doc tool while discovering.
    discover_infer_tool: bool = true,
    /// Git remote name for deploy mode.
    deploy_remote: []const u8 = "origin",
    /// Branch name for deploy mode.
    deploy_branch: []const u8 = "gh-pages",
    /// Commit message for deploy mode.
    deploy_message: []const u8 = "docforge deploy",
    /// Preserve deploy history by accumulating output.
    deploy_preserve_history: bool = false,
};

/// Errors returned while parsing arguments.
pub const ParseError = error{InvalidArgs, MissingValue};

/// Parse arguments from argv.
pub fn parse(argv: []const []const u8) ParseError!Args {
    var args = Args{};

    if (argv.len < 2) {
        return args;
    }

    var i: usize = 1;
    const first = argv[i];
    if (std.mem.eql(u8, first, "run")) {
        args.mode = .run;
        i += 1;
    } else if (std.mem.eql(u8, first, "init")) {
        args.mode = .init;
        i += 1;
    } else if (std.mem.eql(u8, first, "discover") or std.mem.eql(u8, first, "scan")) {
        args.mode = .discover;
        i += 1;
    } else if (std.mem.eql(u8, first, "deploy")) {
        args.mode = .deploy;
        i += 1;
    } else if (std.mem.eql(u8, first, "clean")) {
        args.mode = .clean;
        i += 1;
    } else if (std.mem.eql(u8, first, "list")) {
        args.mode = .list;
        i += 1;
    } else if (std.mem.eql(u8, first, "help") or std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
        args.mode = .help;
        return args;
    } else {
        return ParseError.InvalidArgs;
    }

    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            args.config_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            args.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            args.verbose = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            args.json = true;
        } else if (std.mem.eql(u8, arg, "--incremental")) {
            args.incremental = true;
        } else if (std.mem.eql(u8, arg, "--no-incremental")) {
            args.incremental = false;
        } else if (std.mem.eql(u8, arg, "--insecure")) {
            args.insecure = true;
        } else if ((args.mode == .init or args.mode == .discover) and std.mem.eql(u8, arg, "--username")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            args.init_username = argv[i];
        } else if ((args.mode == .init or args.mode == .discover) and std.mem.eql(u8, arg, "--path")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            args.init_path = argv[i];
        } else if ((args.mode == .init or args.mode == .discover) and std.mem.eql(u8, arg, "--output-dir")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            args.init_output_dir = argv[i];
        } else if (args.mode == .discover and std.mem.eql(u8, arg, "--root")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            args.discover_root = argv[i];
        } else if (args.mode == .discover and std.mem.eql(u8, arg, "--depth")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            args.discover_depth = std.fmt.parseInt(usize, argv[i], 10) catch return ParseError.InvalidArgs;
        } else if (args.mode == .discover and std.mem.eql(u8, arg, "--absolute")) {
            args.discover_absolute = true;
        } else if (args.mode == .discover and std.mem.eql(u8, arg, "--no-infer-tool")) {
            args.discover_infer_tool = false;
        } else if (args.mode == .deploy and std.mem.eql(u8, arg, "--remote")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            args.deploy_remote = argv[i];
        } else if (args.mode == .deploy and std.mem.eql(u8, arg, "--branch")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            args.deploy_branch = argv[i];
        } else if (args.mode == .deploy and std.mem.eql(u8, arg, "--message")) {
            i += 1;
            if (i >= argv.len) return ParseError.MissingValue;
            args.deploy_message = argv[i];
        } else if (args.mode == .deploy and std.mem.eql(u8, arg, "--preserve-history")) {
            args.deploy_preserve_history = true;
        } else {
            return ParseError.InvalidArgs;
        }
    }

    return args;
}

/// Print usage information to a writer.
pub fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        "docforge usage:\n" ++
            "  docforge run [--config path] [--dry-run] [--verbose] [--json] [--incremental|--no-incremental] [--insecure]\n" ++
            "  docforge init [--config path] [--username name] [--path docs] [--output-dir site]\n" ++
            "  docforge discover [--config path] [--root dir] [--depth N] [--username name] [--path docs] [--output-dir site] [--absolute] [--no-infer-tool]\n" ++
            "  docforge deploy [--config path] [--remote origin] [--branch gh-pages] [--message text] [--dry-run] [--verbose] [--json] [--insecure] [--preserve-history]\n" ++
            "  docforge clean [--config path] [--dry-run] [--verbose] [--json]\n" ++
            "  docforge list [--config path] [--json]\n" ++
            "  docforge help\n",
    );
}

test "parse run options" {
    // covers: args.parse
    const argv = &.{ "docforge", "run", "--config", "c.json", "--dry-run", "--json", "--insecure" };
    const parsed = try parse(argv);
    try std.testing.expectEqual(Mode.run, parsed.mode);
    try std.testing.expectEqualStrings("c.json", parsed.config_path);
    try std.testing.expect(parsed.dry_run);
    try std.testing.expect(parsed.json);
    try std.testing.expect(parsed.insecure);
}

test "parse discover options" {
    const argv = &.{ "docforge", "discover", "--root", "repos", "--depth", "3", "--absolute" };
    const parsed = try parse(argv);
    try std.testing.expectEqual(Mode.discover, parsed.mode);
    try std.testing.expectEqualStrings("repos", parsed.discover_root);
    try std.testing.expectEqual(@as(usize, 3), parsed.discover_depth);
    try std.testing.expect(parsed.discover_absolute);
}

test "parse deploy options" {
    const argv = &.{ "docforge", "deploy", "--remote", "upstream", "--branch", "pages", "--message", "ship", "--preserve-history" };
    const parsed = try parse(argv);
    try std.testing.expectEqual(Mode.deploy, parsed.mode);
    try std.testing.expectEqualStrings("upstream", parsed.deploy_remote);
    try std.testing.expectEqualStrings("pages", parsed.deploy_branch);
    try std.testing.expectEqualStrings("ship", parsed.deploy_message);
    try std.testing.expect(parsed.deploy_preserve_history);
}

test "parse clean options" {
    const argv = &.{ "docforge", "clean", "--dry-run", "--json" };
    const parsed = try parse(argv);
    try std.testing.expectEqual(Mode.clean, parsed.mode);
    try std.testing.expect(parsed.dry_run);
    try std.testing.expect(parsed.json);
}

test "parse list options" {
    const argv = &.{ "docforge", "list", "--config", "docforge.json" };
    const parsed = try parse(argv);
    try std.testing.expectEqual(Mode.list, parsed.mode);
    try std.testing.expectEqualStrings("docforge.json", parsed.config_path);
}

test "printUsage emits help text" {
    // covers: args.printUsage
    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try printUsage(stream.writer());
    const output = stream.getWritten();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "docforge run"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "docforge help"));
}
