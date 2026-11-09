//! Command-line argument parsing and usage help formatting for the `generate-all-code-docs` CLI.

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
    config_path: []const u8 = "generate-all-code-docs.json",
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
    deploy_message: []const u8 = "generate-all-code-docs deploy",
    /// Preserve deploy history by accumulating output.
    deploy_preserve_history: bool = false,
};

/// Errors returned while parsing arguments.
pub const ParseError = error{
    /// An unknown subcommand, invalid flag, or malformed value was encountered.
    InvalidArgs,
    /// A flag requiring a parameter was placed at the end of `argv`.
    MissingValue,
};

/// Parse command-line arguments from an `argv` slice.
///
/// @param argv Slice of argument strings where `argv[0]` is the program name.
/// @return Parsed `Args` structure, or `ParseError` if arguments are invalid.
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
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            args.mode = .help;
            return args;
        } else if (std.mem.eql(u8, arg, "--config")) {
            args.config_path = try takeNonEmptyValue(argv, &i);
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
            args.init_username = try takeNonEmptyValue(argv, &i);
        } else if ((args.mode == .init or args.mode == .discover) and std.mem.eql(u8, arg, "--path")) {
            args.init_path = try takeValue(argv, &i);
        } else if ((args.mode == .init or args.mode == .discover) and std.mem.eql(u8, arg, "--output-dir")) {
            args.init_output_dir = try takeNonEmptyValue(argv, &i);
        } else if (args.mode == .discover and std.mem.eql(u8, arg, "--root")) {
            args.discover_root = try takeNonEmptyValue(argv, &i);
        } else if (args.mode == .discover and std.mem.eql(u8, arg, "--depth")) {
            const raw = try takeNonEmptyValue(argv, &i);
            args.discover_depth = std.fmt.parseInt(usize, raw, 10) catch return ParseError.InvalidArgs;
        } else if (args.mode == .discover and std.mem.eql(u8, arg, "--absolute")) {
            args.discover_absolute = true;
        } else if (args.mode == .discover and std.mem.eql(u8, arg, "--no-infer-tool")) {
            args.discover_infer_tool = false;
        } else if (args.mode == .deploy and std.mem.eql(u8, arg, "--remote")) {
            args.deploy_remote = try takeNonEmptyValue(argv, &i);
        } else if (args.mode == .deploy and std.mem.eql(u8, arg, "--branch")) {
            args.deploy_branch = try takeNonEmptyValue(argv, &i);
        } else if (args.mode == .deploy and std.mem.eql(u8, arg, "--message")) {
            args.deploy_message = try takeNonEmptyValue(argv, &i);
        } else if (args.mode == .deploy and std.mem.eql(u8, arg, "--preserve-history")) {
            args.deploy_preserve_history = true;
        } else {
            return ParseError.InvalidArgs;
        }
    }

    return args;
}

/// Advance index `i` and return the next argument in `argv`.
///
/// @param argv Full argument slice.
/// @param i Pointer to current argument index.
/// @return Next argument string, or `ParseError.MissingValue` if at end of `argv`.
fn takeValue(argv: []const []const u8, i: *usize) ParseError![]const u8 {
    i.* += 1;
    if (i.* >= argv.len) return ParseError.MissingValue;
    return argv[i.*];
}

/// Advance index `i` and return the next argument in `argv`, requiring it to be non-empty.
///
/// @param argv Full argument slice.
/// @param i Pointer to current argument index.
/// @return Non-empty next argument string, `ParseError.MissingValue` if missing, or `ParseError.InvalidArgs` if empty.
fn takeNonEmptyValue(argv: []const []const u8, i: *usize) ParseError![]const u8 {
    const val = try takeValue(argv, i);
    if (val.len == 0) return ParseError.InvalidArgs;
    return val;
}

/// Print CLI usage information to a concrete `*std.Io.Writer`.
///
/// @param writer Output stream writer.
pub fn printUsage(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(
        "generate-all-code-docs usage:\x0a" ++
            "  generate-all-code-docs run [--config path] [--dry-run] [--verbose] [--json] [--incremental|--no-incremental] [--insecure]\x0a" ++
            "  generate-all-code-docs init [--config path] [--username name] [--path docs] [--output-dir site]\x0a" ++
            "  generate-all-code-docs discover [--config path] [--root dir] [--depth N] [--username name] [--path docs] [--output-dir site] [--absolute] [--no-infer-tool]\x0a" ++
            "  generate-all-code-docs deploy [--config path] [--remote origin] [--branch gh-pages] [--message text] [--dry-run] [--verbose] [--json] [--insecure] [--preserve-history]\x0a" ++
            "  generate-all-code-docs clean [--config path] [--dry-run] [--verbose] [--json]\x0a" ++
            "  generate-all-code-docs list [--config path] [--json]\x0a" ++
            "  generate-all-code-docs help\x0a",
    );
}

test "parse handles default help, explicit help, and --help after subcommand" {
    // covers: args.parse
    const empty_parsed = try parse(&.{"generate-all-code-docs"});
    try std.testing.expectEqual(Mode.help, empty_parsed.mode);

    const help_word = try parse(&.{ "generate-all-code-docs", "help" });
    try std.testing.expectEqual(Mode.help, help_word.mode);

    const help_flag = try parse(&.{ "generate-all-code-docs", "--help" });
    try std.testing.expectEqual(Mode.help, help_flag.mode);

    const h_flag = try parse(&.{ "generate-all-code-docs", "-h" });
    try std.testing.expectEqual(Mode.help, h_flag.mode);

    const sub_help = try parse(&.{ "generate-all-code-docs", "run", "--help" });
    try std.testing.expectEqual(Mode.help, sub_help.mode);

    const sub_h = try parse(&.{ "generate-all-code-docs", "deploy", "-h" });
    try std.testing.expectEqual(Mode.help, sub_h.mode);
}

test "parse run options and incremental flags" {
    const argv = &.{ "generate-all-code-docs", "run", "--config", "c.json", "--dry-run", "--verbose", "--json", "--no-incremental", "--incremental", "--insecure" };
    const parsed = try parse(argv);
    try std.testing.expectEqual(Mode.run, parsed.mode);
    try std.testing.expectEqualStrings("c.json", parsed.config_path);
    try std.testing.expect(parsed.dry_run);
    try std.testing.expect(parsed.verbose);
    try std.testing.expect(parsed.json);
    try std.testing.expect(parsed.incremental);
    try std.testing.expect(parsed.insecure);

    const no_inc = try parse(&.{ "generate-all-code-docs", "run", "--no-incremental" });
    try std.testing.expect(!no_inc.incremental);
}

test "parse init and discover options including scan alias" {
    // covers: args.takeValue args.takeNonEmptyValue
    const init_parsed = try parse(&.{ "generate-all-code-docs", "init", "--username", "alice", "--path", "", "--output-dir", "out" });
    try std.testing.expectEqual(Mode.init, init_parsed.mode);
    try std.testing.expectEqualStrings("alice", init_parsed.init_username);
    try std.testing.expectEqualStrings("", init_parsed.init_path);
    try std.testing.expectEqualStrings("out", init_parsed.init_output_dir);

    const scan_parsed = try parse(&.{
        "generate-all-code-docs",
        "scan",
        "--root",
        "repos",
        "--depth",
        "3",
        "--absolute",
        "--no-infer-tool",
        "--username",
        "bob",
        "--path",
        "api",
        "--output-dir",
        "public",
    });
    try std.testing.expectEqual(Mode.discover, scan_parsed.mode);
    try std.testing.expectEqualStrings("repos", scan_parsed.discover_root);
    try std.testing.expectEqual(@as(usize, 3), scan_parsed.discover_depth);
    try std.testing.expect(scan_parsed.discover_absolute);
    try std.testing.expect(!scan_parsed.discover_infer_tool);
    try std.testing.expectEqualStrings("bob", scan_parsed.init_username);
    try std.testing.expectEqualStrings("api", scan_parsed.init_path);
    try std.testing.expectEqualStrings("public", scan_parsed.init_output_dir);
}

test "parse deploy, clean, and list options" {
    const deploy_parsed = try parse(&.{ "generate-all-code-docs", "deploy", "--remote", "upstream", "--branch", "pages", "--message", "ship", "--preserve-history" });
    try std.testing.expectEqual(Mode.deploy, deploy_parsed.mode);
    try std.testing.expectEqualStrings("upstream", deploy_parsed.deploy_remote);
    try std.testing.expectEqualStrings("pages", deploy_parsed.deploy_branch);
    try std.testing.expectEqualStrings("ship", deploy_parsed.deploy_message);
    try std.testing.expect(deploy_parsed.deploy_preserve_history);

    const clean_parsed = try parse(&.{ "generate-all-code-docs", "clean", "--dry-run", "--json" });
    try std.testing.expectEqual(Mode.clean, clean_parsed.mode);
    try std.testing.expect(clean_parsed.dry_run);
    try std.testing.expect(clean_parsed.json);

    const list_parsed = try parse(&.{ "generate-all-code-docs", "list", "--config", "generate-all-code-docs.json" });
    try std.testing.expectEqual(Mode.list, list_parsed.mode);
    try std.testing.expectEqualStrings("generate-all-code-docs.json", list_parsed.config_path);
}

test "parse rejects invalid subcommands, missing values, empty values, and invalid depth" {
    try std.testing.expectError(ParseError.InvalidArgs, parse(&.{ "generate-all-code-docs", "unknown" }));
    try std.testing.expectError(ParseError.InvalidArgs, parse(&.{ "generate-all-code-docs", "run", "--unknown" }));
    try std.testing.expectError(ParseError.InvalidArgs, parse(&.{ "generate-all-code-docs", "run", "--username", "sam" }));
    try std.testing.expectError(ParseError.InvalidArgs, parse(&.{ "generate-all-code-docs", "discover", "--depth", "notanumber" }));
    try std.testing.expectError(ParseError.InvalidArgs, parse(&.{ "generate-all-code-docs", "run", "--config", "" }));

    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "generate-all-code-docs", "run", "--config" }));
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "generate-all-code-docs", "init", "--username" }));
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "generate-all-code-docs", "init", "--path" }));
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "generate-all-code-docs", "init", "--output-dir" }));
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "generate-all-code-docs", "discover", "--root" }));
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "generate-all-code-docs", "discover", "--depth" }));
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "generate-all-code-docs", "deploy", "--remote" }));
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "generate-all-code-docs", "deploy", "--branch" }));
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "generate-all-code-docs", "deploy", "--message" }));
}

test "printUsage emits help text" {
    // covers: args.printUsage
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try printUsage(&writer);
    const output = writer.buffered();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "generate-all-code-docs run"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "generate-all-code-docs help"));
}
