//! Entry point for the prise terminal multiplexer client.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const crash_context = @import("crash_context.zig");
const io = @import("io.zig");
const msgpack = @import("msgpack.zig");
const rpc = @import("rpc.zig");
const session_json = @import("session_json.zig");
const server = @import("server.zig");
const client = @import("client.zig");
const posix = std.posix;

pub const version = build_options.version;

const log = std.log.scoped(.main);

/// Result of parsing command-line arguments.
const ParseResult = struct {
    /// Session name to attach to (existing session)
    attach_session: ?[]const u8 = null,
    /// Session name for a new session (user-specified)
    new_session_name: ?[]const u8 = null,
    /// Create session without attaching (-d/--detached)
    detached: bool = false,
};

const TabRenameContext = struct {
    session_name: ?[]const u8,
    pty_id: u32,
    pty_validity: i64,
};

var log_file: ?std.fs.File = null;

pub const std_options: std.Options = .{
    .logFn = fileLogFn,
    .log_scope_levels = &.{
        .{ .scope = .page_list, .level = .warn },
    },
};

pub const panic = std.debug.FullPanic(panicHandler);

var log_buffer: [4096]u8 = undefined;

/// Write directly to the log file, bypassing std.log. Silent when log_file
/// is null (e.g. during tests) so messages don't leak into test runner stderr.
fn logDirect(comptime format: []const u8, args: anytype) void {
    const file = log_file orelse return;
    const msg = std.fmt.bufPrint(&log_buffer, format ++ "\n", args) catch return;
    _ = file.write(msg) catch {};
}

fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    var buf: [320]u8 = undefined;
    const reason = std.fmt.bufPrint(&buf, "panic: {s}", .{msg}) catch "panic";

    // Capture a stack trace into a fixed-size buffer so the crash bundle has
    // something to symbolicate later. 32 frames is enough to identify most
    // panic origins without inflating bundle size.
    var addrs: [32]usize = undefined;
    var trace: std.builtin.StackTrace = .{
        .instruction_addresses = &addrs,
        .index = 0,
    };
    if (first_trace_addr) |addr| std.debug.captureStackTrace(addr, &trace);

    crash_context.writeBundle(reason, null, &trace);
    std.debug.defaultPanic(msg, first_trace_addr);
}

fn fileLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const file = log_file orelse return;
    const scope_prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    const prefix = "[" ++ comptime level.asText() ++ "] " ++ scope_prefix;
    const msg = std.fmt.bufPrint(&log_buffer, prefix ++ format ++ "\n", args) catch return;
    _ = file.write(msg) catch {};
}

const MAX_LOG_SIZE = 64 * 1024 * 1024; // 64 MiB

fn getLogDir(buf: []u8) ?[]const u8 {
    const home = posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.cache/prise", .{home}) catch null;
}

fn initLogFile(filename: []const u8) void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_dir = getLogDir(&path_buf) orelse return;

    std.fs.makeDirAbsolute(log_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return,
    };

    var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_path = std.fmt.bufPrint(&file_path_buf, "{s}/{s}", .{ log_dir, filename }) catch return;

    if (std.fs.openFileAbsolute(log_path, .{ .mode = .read_write })) |file| {
        const stat = file.stat() catch {
            file.close();
            return;
        };
        if (stat.size > MAX_LOG_SIZE) {
            file.setEndPos(0) catch {};
            file.seekTo(0) catch {};
        } else {
            file.seekFromEnd(0) catch {};
        }
        log_file = file;
    } else |_| {
        log_file = std.fs.createFileAbsolute(log_path, .{}) catch return;
    }
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const uid = posix.getuid();
    var socket_buffer: [256]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&socket_buffer, "/tmp/prise-{d}.sock", .{uid});

    const result = try parseArgs(allocator, socket_path) orelse return;
    defer {
        if (result.attach_session) |s| allocator.free(s);
        if (result.new_session_name) |s| allocator.free(s);
    }
    // Detect nesting: if PRISE_PTY is set, we're inside a prise session
    if (posix.getenv("PRISE_PTY")) |pty_id_str| {
        const target_session = result.new_session_name orelse result.attach_session orelse {
            const current = posix.getenv("PRISE_SESSION") orelse "unknown";
            var err_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&err_buf,
                \\Already inside prise session '{s}'.
                \\Use 'prise -s <name>' to create and switch to a new session.
                \\
            , .{current}) catch return;
            std.fs.File.stderr().writeAll(msg) catch {};
            return;
        };

        const pty_id = std.fmt.parseInt(u32, pty_id_str, 10) catch {
            std.fs.File.stderr().writeAll("error: invalid PRISE_PTY value\n") catch {};
            return;
        };

        // If this is a new session (-s <name> where name didn't exist),
        // create a minimal session file so the client can switch to it
        if (result.new_session_name != null) {
            createMinimalSession(allocator, target_session) catch |err| {
                var msg_buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "error: failed to create session '{s}': {s}\n", .{ target_session, @errorName(err) }) catch return;
                std.fs.File.stderr().writeAll(msg) catch {};
                return;
            };
        }

        requestNestedSessionSwitch(allocator, socket_path, target_session, pty_id) catch |err| {
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "error: failed to switch session: {s}\n", .{@errorName(err)}) catch return;
            std.fs.File.stderr().writeAll(msg) catch {};
            return;
        };

        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Switching to session '{s}'...\n", .{target_session}) catch return;
        std.fs.File.stdout().writeAll(msg) catch {};
        return;
    }

    if (result.detached) {
        createDetachedSession(allocator, socket_path, result.new_session_name.?) catch |err| {
            if (err == error.ServerNotRunning) {
                try std.fs.File.stderr().writeAll(
                    \\Server not running. Start with:
                    \\    prise serve
                    \\
                );
            }
            return;
        };
        return;
    }

    runClient(allocator, socket_path, result) catch |err| {
        var log_dir_buf: [std.fs.max_path_bytes]u8 = undefined;

        if (err == error.ServerNotRunning) {
            try std.fs.File.stderr().writeAll(
                \\Server not running. Start with:
                \\    prise serve
                \\
                \\For automatic startup, see 'man prise.7'
                \\
            );
        } else if (getLogDir(&log_dir_buf)) |log_dir| {
            var msg_buf: [1024]u8 = undefined;
            const msg = try std.fmt.bufPrint(&msg_buf,
                \\Unexpected error: {s}
                \\
                \\Check logs for details:
                \\    {s}/client.log
                \\    {s}/server.log
                \\
            , .{ @errorName(err), log_dir, log_dir });
            try std.fs.File.stderr().writeAll(msg);
        } else {
            return err;
        }
        return;
    };
}

fn parseArgs(allocator: std.mem.Allocator, socket_path: []const u8) !?ParseResult {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    var result: ParseResult = .{};
    errdefer if (result.new_session_name) |s| allocator.free(s);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            try printVersion();
            return null;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp();
            return null;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--session")) {
            const name = args.next() orelse {
                printSessionNameError("error: -s/--session requires a session name\n");
                return error.MissingArgument;
            };
            validateSessionName(name) catch |err| {
                printSessionNameValidationError(err);
                return err;
            };
            if (sessionExists(allocator, name)) {
                // When nested, -s switches to the existing session
                if (posix.getenv("PRISE_PTY") != null) {
                    result.attach_session = try allocator.dupe(u8, name);
                } else {
                    var err_buf: [128]u8 = undefined;
                    const msg = std.fmt.bufPrint(&err_buf, "error: session '{s}' already exists\n", .{name}) catch return error.SessionAlreadyExists;
                    printSessionNameError(msg);
                    return error.SessionAlreadyExists;
                }
            } else {
                result.new_session_name = try allocator.dupe(u8, name);
            }
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--detached")) {
            result.detached = true;
        } else if (std.mem.eql(u8, arg, "serve")) {
            initLogFile("server.log");
            try server.startServer(allocator, socket_path);
            return null;
        } else if (std.mem.eql(u8, arg, "session")) {
            if (result.new_session_name != null) {
                printSessionNameError("error: -s/--session cannot be used with 'session attach'\n");
                return error.ConflictingOptions;
            }
            const session_result = try handleSessionCommand(allocator, &args) orelse return null;
            result.attach_session = session_result.attach_session;
            return result;
        } else if (std.mem.eql(u8, arg, "pty")) {
            _ = try handlePtyCommand(allocator, &args, socket_path);
            return null;
        } else if (std.mem.eql(u8, arg, "tab")) {
            _ = try handleTabCommand(allocator, &args, socket_path);
            return null;
        } else if (std.mem.eql(u8, arg, "plug")) {
            _ = try handlePlugCommand(allocator, &args, socket_path);
            return null;
        } else {
            log.err("Unknown command: {s}", .{arg});
            try printHelp();
            return error.UnknownCommand;
        }
    }

    if (result.detached and result.new_session_name == null) {
        printSessionNameError("error: --detached requires -s/--session <name>\n");
        return error.MissingArgument;
    }

    return result;
}

fn printVersion() !void {
    var buf: [128]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    defer stdout.interface.flush() catch {};
    try stdout.interface.print("prise {s}\n", .{version});
}

const MAX_SESSION_NAME_LEN = 64;

fn validateSessionName(name: []const u8) !void {
    if (name.len == 0) return error.SessionNameEmpty;
    if (name.len > MAX_SESSION_NAME_LEN) return error.SessionNameTooLong;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') {
            return error.SessionNameInvalid;
        }
    }
}

fn sessionExists(allocator: std.mem.Allocator, name: []const u8) bool {
    const result = getSessionsDir(allocator) catch return false;
    defer allocator.free(result.path);
    var dir = result.dir;
    defer dir.close();

    var filename_buf: [256]u8 = undefined;
    const filename = std.fmt.bufPrint(&filename_buf, "{s}.json", .{name}) catch return false;

    dir.access(filename, .{}) catch return false;
    return true;
}

fn printSessionNameError(msg: []const u8) void {
    std.fs.File.stderr().writeAll(msg) catch {};
}

fn printSessionNameValidationError(err: anyerror) void {
    const msg = switch (err) {
        error.SessionNameEmpty => "error: session name cannot be empty\n",
        error.SessionNameTooLong => "error: session name must be 64 characters or fewer\n",
        error.SessionNameInvalid => "error: session name may only contain letters, numbers, dashes, and underscores\n",
        else => "error: invalid session name\n",
    };
    printSessionNameError(msg);
}

fn printHelp() !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    defer stdout.interface.flush() catch {};
    try stdout.interface.print(
        \\prise - Terminal multiplexer
        \\
        \\Usage: prise [options] [command]
        \\
        \\Commands:
        \\  (none)     Start client, connect to server (spawns server if needed)
        \\  serve      Start the server in the foreground
        \\  session    Manage sessions (attach, list, rename, delete)
        \\  pty        Manage PTYs (list, kill)
        \\  tab        Manage tabs (rename)
        \\  plug       Manage plugs (list)
        \\
        \\Options:
        \\  -s, --session <name>  Create a new session with the specified name
        \\  -d, --detached        With -s, create session without attaching
        \\  -h, --help            Show this help message
        \\  -v, --version         Show version
        \\
        \\Run 'prise <command> --help' for more information on a command.
        \\
    , .{});
}

fn printSessionHelp() !void {
    try printSessionHelpTo(std.fs.File.stdout());
}

fn printSessionHelpTo(file: std.fs.File) !void {
    var buf: [4096]u8 = undefined;
    var writer = file.writer(&buf);
    defer writer.interface.flush() catch {};
    try writer.interface.print(
        \\prise session - Manage sessions
        \\
        \\Usage: prise session <command> [args]
        \\
        \\Commands:
        \\  attach [name]            Attach to a session (most recent if no name given)
        \\  list                     List all sessions
        \\  rename <old> <new>       Rename a session
        \\  delete <name>            Delete a session
        \\
        \\Options:
        \\  -h, --help               Show this help message
        \\
    , .{});
}

fn handleSessionCommand(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !?ParseResult {
    const subcmd = args.next() orelse {
        try printSessionHelp();
        return error.MissingCommand;
    };

    if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        try printSessionHelp();
        return null;
    } else if (std.mem.eql(u8, subcmd, "attach")) {
        const session = if (args.next()) |s|
            try allocator.dupe(u8, s)
        else
            findMostRecentSession(allocator) catch |err| {
                if (err == error.NoSessionsFound) {
                    std.fs.File.stderr().writeAll("No sessions found\n") catch {};
                    return null;
                }
                return err;
            };
        if (!sessionExists(allocator, session)) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Session '{s}' not found\n", .{session}) catch return null;
            std.fs.File.stderr().writeAll(msg) catch {};
            allocator.free(session);
            return null;
        }
        return .{ .attach_session = session };
    } else if (std.mem.eql(u8, subcmd, "list")) {
        try listSessions(allocator);
        return null;
    } else if (std.mem.eql(u8, subcmd, "rename")) {
        const old_name = args.next() orelse {
            std.fs.File.stderr().writeAll("Missing session name. Usage: prise session rename <old-name> <new-name>\n\nAvailable sessions:\n") catch {};
            try listSessionsTo(allocator, std.fs.File.stderr());
            return error.MissingArgument;
        };
        const new_name = args.next() orelse {
            std.fs.File.stderr().writeAll("Missing new session name. Usage: prise session rename <old-name> <new-name>\n") catch {};
            return error.MissingArgument;
        };
        try renameSession(allocator, old_name, new_name);
        return null;
    } else if (std.mem.eql(u8, subcmd, "delete")) {
        const name = args.next() orelse {
            std.fs.File.stderr().writeAll("Missing session name. Usage: prise session delete <name>\n\nAvailable sessions:\n") catch {};
            try listSessionsTo(allocator, std.fs.File.stderr());
            return error.MissingArgument;
        };
        try deleteSession(allocator, name);
        return null;
    } else {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Unknown session command: {s}\n\n", .{subcmd}) catch return error.UnknownCommand;
        std.fs.File.stderr().writeAll(msg) catch {};
        try printSessionHelpTo(std.fs.File.stderr());
        return error.UnknownCommand;
    }
}

fn printPtyHelp() !void {
    try printPtyHelpTo(std.fs.File.stdout());
}

fn printPtyHelpTo(file: std.fs.File) !void {
    var buf: [4096]u8 = undefined;
    var writer = file.writer(&buf);
    defer writer.interface.flush() catch {};
    try writer.interface.print(
        \\prise pty - Manage PTYs
        \\
        \\Usage: prise pty <command> [args]
        \\
        \\Commands:
        \\  list                     List all PTYs
        \\  kill <id>                Kill a PTY by ID
        \\
        \\Options:
        \\  -h, --help               Show this help message
        \\
    , .{});
}

fn handlePtyCommand(allocator: std.mem.Allocator, args: *std.process.ArgIterator, socket_path: []const u8) !?ParseResult {
    const subcmd = args.next() orelse {
        try printPtyHelp();
        return error.MissingCommand;
    };

    if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        try printPtyHelp();
        return null;
    } else if (std.mem.eql(u8, subcmd, "list")) {
        try listPtys(allocator, socket_path);
        return null;
    } else if (std.mem.eql(u8, subcmd, "kill")) {
        const id_str = args.next() orelse {
            std.fs.File.stderr().writeAll("Missing PTY ID. Usage: prise pty kill <id>\n\nUse 'prise pty list' to see available PTYs.\n") catch {};
            return error.MissingArgument;
        };
        const pty_id = std.fmt.parseInt(u32, id_str, 10) catch {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Invalid PTY ID: {s}\n", .{id_str}) catch return error.InvalidArgument;
            std.fs.File.stderr().writeAll(msg) catch {};
            return error.InvalidArgument;
        };
        try killPty(allocator, socket_path, pty_id);
        return null;
    } else {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Unknown pty command: {s}\n\n", .{subcmd}) catch return error.UnknownCommand;
        std.fs.File.stderr().writeAll(msg) catch {};
        try printPtyHelpTo(std.fs.File.stderr());
        return error.UnknownCommand;
    }
}

fn handleTabCommand(allocator: std.mem.Allocator, args: *std.process.ArgIterator, socket_path: []const u8) !?ParseResult {
    const subcmd = args.next() orelse {
        try printTabHelp();
        return error.MissingCommand;
    };

    if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        try printTabHelp();
        return null;
    } else if (std.mem.eql(u8, subcmd, "rename")) {
        const new_title = args.next() orelse {
            std.fs.File.stderr().writeAll("Missing title. Usage: prise tab rename <title>\n") catch {};
            return error.MissingArgument;
        };
        initLogFile("client.log");
        const context = try getTabRenameContext();
        try executeTabRename(allocator, resolvePriseSocketPath(socket_path), null, context, new_title);
        return null;
    } else {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Unknown tab command: {s}\n\n", .{subcmd}) catch return error.UnknownCommand;
        std.fs.File.stderr().writeAll(msg) catch {};
        try printTabHelpTo(std.fs.File.stderr());
        return error.UnknownCommand;
    }
}

fn printTabHelp() !void {
    try printTabHelpTo(std.fs.File.stdout());
}

fn printTabHelpTo(file: std.fs.File) !void {
    var buf: [4096]u8 = undefined;
    var writer = file.writer(&buf);
    defer writer.interface.flush() catch {};
    try writer.interface.print(
        \\prise tab - Manage tabs
        \\
        \\Usage: prise tab <command> [args]
        \\
        \\Commands:
        \\  rename <title>           Set the tab title (run from within prise)
        \\
        \\Options:
        \\  -h, --help               Show this help message
        \\
    , .{});
}

fn handlePlugCommand(allocator: std.mem.Allocator, args: *std.process.ArgIterator, socket_path: []const u8) !?ParseResult {
    const subcmd = args.next() orelse {
        try printPlugHelp();
        return error.MissingCommand;
    };

    if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        try printPlugHelp();
        return null;
    } else if (std.mem.eql(u8, subcmd, "list")) {
        initLogFile("client.log");
        try listPlugs(allocator, resolvePriseSocketPath(socket_path));
        return null;
    } else {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Unknown plug command: {s}\n\n", .{subcmd}) catch return error.UnknownCommand;
        std.fs.File.stderr().writeAll(msg) catch {};
        try printPlugHelpTo(std.fs.File.stderr());
        return error.UnknownCommand;
    }
}

fn printPlugHelp() !void {
    try printPlugHelpTo(std.fs.File.stdout());
}

fn printPlugHelpTo(file: std.fs.File) !void {
    var buf: [4096]u8 = undefined;
    var writer = file.writer(&buf);
    defer writer.interface.flush() catch {};
    try writer.interface.print(
        \\prise plug - Manage plugs
        \\
        \\Usage: prise plug <command>
        \\
        \\Commands:
        \\  list                     List connected plugs
        \\
        \\Options:
        \\  -h, --help               Show this help message
        \\
    , .{});
}

fn listPlugs(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    const sock = try connectToServer(socket_path);
    defer posix.close(sock);

    const request = try msgpack.encode(allocator, .{ 0, 1, "list_plugs", .{} });
    defer allocator.free(request);

    const msg = try sendRpcRequest(allocator, sock, request);
    defer msg.deinit(allocator);

    if (msg != .response) return error.InvalidResponse;
    if (msg.response.err != null) return error.ServerError;
    if (msg.response.result != .map) return error.InvalidResponse;

    var plugs: ?[]const msgpack.Value = null;
    for (msg.response.result.map) |kv| {
        if (kv.key == .string and std.mem.eql(u8, kv.key.string, "plugs")) {
            if (kv.value == .array) plugs = kv.value.array;
        }
    }

    const plug_list = plugs orelse return error.InvalidResponse;

    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    defer stdout.interface.flush() catch {};

    if (plug_list.len == 0) {
        try stdout.interface.print("No plugs configured\n", .{});
        return;
    }

    try stdout.interface.print("{s:<20} {s:<12} {s:<10} {s:<10} {s}\n", .{
        "NAME", "STATUS", "PID", "RESTARTS", "AUTO-RESTART",
    });
    try stdout.interface.print("{s:<20} {s:<12} {s:<10} {s:<10} {s}\n", .{
        "----", "------", "---", "--------", "------------",
    });

    for (plug_list) |plug_val| {
        if (plug_val != .map) continue;
        try printPlugRow(&stdout, plug_val.map);
    }
}

fn printPlugRow(stdout: anytype, entries: []const msgpack.Value.KeyValue) !void {
    var name: []const u8 = "?";
    var registered: bool = false;
    var pid: ?i64 = null;
    var restart_count: u64 = 0;
    var restart: bool = false;

    for (entries) |kv| {
        if (kv.key != .string) continue;
        if (std.mem.eql(u8, kv.key.string, "name") and kv.value == .string) {
            name = kv.value.string;
        } else if (std.mem.eql(u8, kv.key.string, "registered") and kv.value == .boolean) {
            registered = kv.value.boolean;
        } else if (std.mem.eql(u8, kv.key.string, "pid")) {
            pid = switch (kv.value) {
                .integer => |i| i,
                .unsigned => |u| @intCast(u),
                else => null,
            };
        } else if (std.mem.eql(u8, kv.key.string, "restart_count")) {
            restart_count = switch (kv.value) {
                .unsigned => |u| u,
                .integer => |i| @intCast(i),
                else => 0,
            };
        } else if (std.mem.eql(u8, kv.key.string, "restart") and kv.value == .boolean) {
            restart = kv.value.boolean;
        }
    }

    const status = if (registered) "connected" else if (pid != null) "starting" else "stopped";
    const restart_str = if (restart) "yes" else "no";

    if (pid) |p| {
        try stdout.interface.print("{s:<20} {s:<12} {d:<10} {d:<10} {s}\n", .{
            name, status, p, restart_count, restart_str,
        });
    } else {
        try stdout.interface.print("{s:<20} {s:<12} {s:<10} {d:<10} {s}\n", .{
            name, status, "-", restart_count, restart_str,
        });
    }
}

fn resolvePriseSocketPath(default_socket_path: []const u8) []const u8 {
    return posix.getenv("PRISE_SOCKET") orelse default_socket_path;
}

fn getTabRenameContext() !TabRenameContext {
    const pty_id_str = posix.getenv("PRISE_PTY") orelse {
        std.fs.File.stderr().writeAll("Not running inside prise (PRISE_PTY not set).\n") catch {};
        return error.MissingArgument;
    };
    const pty_validity_str = posix.getenv("PRISE_PTY_VALIDITY") orelse {
        std.fs.File.stderr().writeAll("Not running inside prise (PRISE_PTY_VALIDITY not set).\n") catch {};
        return error.MissingArgument;
    };

    const pty_id = std.fmt.parseInt(u32, pty_id_str, 10) catch {
        std.fs.File.stderr().writeAll("Invalid PRISE_PTY value.\n") catch {};
        return error.InvalidArgument;
    };
    const pty_validity = std.fmt.parseInt(i64, pty_validity_str, 10) catch {
        std.fs.File.stderr().writeAll("Invalid PRISE_PTY_VALIDITY value.\n") catch {};
        return error.InvalidArgument;
    };

    return .{
        .session_name = posix.getenv("PRISE_SESSION"),
        .pty_id = pty_id,
        .pty_validity = pty_validity,
    };
}

fn persistTabRename(allocator: std.mem.Allocator, session_name: []const u8, pty_id: u32, title: ?[]const u8) !void {
    const result = getSessionsDir(allocator) catch |err| switch (err) {
        error.NoSessionsFound => return,
        else => return err,
    };
    defer allocator.free(result.path);
    var dir = result.dir;
    dir.close();

    try persistTabRenameInSessionsDir(allocator, result.path, session_name, pty_id, title);
}

fn persistTabRenameInSessionsDir(
    allocator: std.mem.Allocator,
    sessions_dir_path: []const u8,
    session_name: []const u8,
    pty_id: u32,
    title: ?[]const u8,
) !void {
    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{session_name});
    defer allocator.free(file_name);

    const session_path = try std.fs.path.join(allocator, &.{ sessions_dir_path, file_name });
    defer allocator.free(session_path);

    _ = try session_json.updateTabTitleFile(allocator, session_path, pty_id, title);
}

fn executeTabRename(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    sessions_dir_path: ?[]const u8,
    context: TabRenameContext,
    new_title: []const u8,
) !void {
    try renameTab(allocator, socket_path, context.pty_id, context.pty_validity, new_title);

    if (context.session_name) |session_name| {
        const title = if (new_title.len > 0) new_title else null;
        if (sessions_dir_path) |dir_path| {
            try persistTabRenameInSessionsDir(allocator, dir_path, session_name, context.pty_id, title);
        } else {
            try persistTabRename(allocator, session_name, context.pty_id, title);
        }
    }
}

fn readRpcResponseMessage(allocator: std.mem.Allocator, sock: posix.fd_t) !rpc.Message {
    var response_buf: [4096]u8 = undefined;
    const n = try posix.read(sock, &response_buf);
    if (n == 0) return error.NoResponse;
    return rpc.decodeMessage(allocator, response_buf[0..n]);
}

fn renameTab(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    pty_id: u32,
    pty_validity: i64,
    title: []const u8,
) !void {
    const sock = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch |err| {
        log.err("Failed to create socket: {}", .{err});
        return error.SocketError;
    };
    defer posix.close(sock);

    var addr: posix.sockaddr.un = .{ .path = undefined };
    @memcpy(addr.path[0..socket_path.len], socket_path);
    addr.path[socket_path.len] = 0;

    posix.connect(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            logDirect("Server not running", .{});
            return error.ServerNotRunning;
        }
        return err;
    };

    var map_items = [3]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "pty_id" }, .value = .{ .unsigned = pty_id } },
        .{ .key = .{ .string = "title" }, .value = .{ .string = title } },
        .{ .key = .{ .string = "pty_validity" }, .value = .{ .integer = pty_validity } },
    };
    const params = msgpack.Value{ .map = &map_items };
    const request = try msgpack.encode(allocator, .{ 0, 1, "rename_tab", params });
    defer allocator.free(request);

    _ = try posix.write(sock, request);

    const msg = readRpcResponseMessage(allocator, sock) catch |err| {
        switch (err) {
            error.NoResponse => logDirect("No response from server", .{}),
            else => logDirect("Failed to read rename_tab response: {}", .{err}),
        }
        return err;
    };
    defer msg.deinit(allocator);

    if (msg != .response) {
        logDirect("Unexpected response type", .{});
        return error.InvalidResponse;
    }

    if (msg.response.err) |err_val| {
        const err_str = if (err_val == .string) err_val.string else "unknown error";
        logDirect("Server error: {s}", .{err_str});
        return error.ServerError;
    }

    if (msg.response.result != .string) {
        logDirect("Invalid response format", .{});
        return error.InvalidResponse;
    }

    if (!std.mem.eql(u8, msg.response.result.string, "ok")) {
        logDirect("{s}", .{msg.response.result.string});
        return error.RenameRejected;
    }
}

fn runClient(allocator: std.mem.Allocator, socket_path: []const u8, args: ParseResult) !void {
    std.fs.accessAbsolute(socket_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            log.err("Server not running. Start it with: prise serve", .{});
            return error.ServerNotRunning;
        }
        return err;
    };

    crash_context.init(.client, version);
    defer crash_context.deinit();
    crash_context.setSocketPath(socket_path);
    crash_context.record("client run start", .{});

    initLogFile("client.log");
    log.info("Connecting to server at {s}", .{socket_path});

    var loop = try io.Loop.init(allocator);
    defer loop.deinit();

    var app = switch (client.App.init(allocator)) {
        .ok => |a| a,
        .err => |init_err| {
            var buf: [512]u8 = undefined;
            var stderr = std.fs.File.stderr().writer(&buf);
            defer stderr.interface.flush() catch {};
            switch (init_err.err) {
                error.InitLuaMustReturnTable => stderr.interface.print("error: init.lua must return a UI table\n  example: return require('prise').tiling()\n  see: man 5 prise\n", .{}) catch {},
                error.InitLuaFailed => {
                    if (init_err.lua_msg) |lua_msg| {
                        stderr.interface.print("error: {s}\n  see: man 5 prise\n", .{lua_msg}) catch {};
                    } else {
                        stderr.interface.print("error: failed to load init.lua\n  see: man 5 prise\n", .{}) catch {};
                    }
                },
                error.DefaultUIFailed => {
                    if (init_err.lua_msg) |lua_msg| {
                        stderr.interface.print("error: failed to load default UI: {s}\n", .{lua_msg}) catch {};
                    } else {
                        stderr.interface.print("error: failed to load default UI\n", .{}) catch {};
                    }
                },
                else => {},
            }
            return init_err.err;
        },
    };
    defer app.deinit();
    errdefer |err| {
        const reason = if (err == error.ConnectionRefused) "connection refused" else @errorName(err);
        app.writeCrashBundle(reason);
    }

    // Initialize TTY after App is in its final memory location
    // (tty writer holds pointer to tty_buffer)
    try app.initTty();

    app.socket_path = socket_path;
    app.attach_session = args.attach_session;
    app.new_session_name = args.new_session_name;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    app.initial_cwd = posix.getcwd(&cwd_buf) catch null;

    try app.setup(&loop);
    try loop.run(.until_done);

    if (app.state.connection_refused) {
        log.err("Connection refused. Server may have crashed. Start it with: prise serve", .{});
        posix.unlink(socket_path) catch {};
        return error.ConnectionRefused;
    }
}

fn getSessionsDir(allocator: std.mem.Allocator) !struct { dir: std.fs.Dir, path: []const u8 } {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;
    const sessions_dir = try std.fs.path.join(allocator, &.{ home, ".local", "state", "prise", "sessions" });

    const dir = std.fs.openDirAbsolute(sessions_dir, .{ .iterate = true }) catch |err| {
        allocator.free(sessions_dir);
        if (err == error.FileNotFound) {
            return error.NoSessionsFound;
        }
        return err;
    };

    return .{ .dir = dir, .path = sessions_dir };
}

fn listSessions(allocator: std.mem.Allocator) !void {
    try listSessionsTo(allocator, std.fs.File.stdout());
}

fn listSessionsTo(allocator: std.mem.Allocator, file: std.fs.File) !void {
    var buf: [4096]u8 = undefined;
    var writer = file.writer(&buf);
    defer writer.interface.flush() catch {};

    const result = getSessionsDir(allocator) catch |err| {
        if (err == error.NoSessionsFound) {
            try writer.interface.print("No sessions found.\n", .{});
            return;
        }
        return err;
    };
    defer allocator.free(result.path);
    var dir = result.dir;
    defer dir.close();

    var count: usize = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const name_without_ext = entry.name[0 .. entry.name.len - 5];
        try writer.interface.print("{s}\n", .{name_without_ext});
        count += 1;
    }

    if (count == 0) {
        try writer.interface.print("No sessions found.\n", .{});
    }
}

fn renameSession(allocator: std.mem.Allocator, old_name: []const u8, new_name: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    defer stdout.interface.flush() catch {};

    const result = getSessionsDir(allocator) catch |err| {
        if (err == error.NoSessionsFound) {
            try stdout.interface.print("Session '{s}' not found.\n", .{old_name});
            return error.SessionNotFound;
        }
        return err;
    };
    defer allocator.free(result.path);
    var dir = result.dir;
    defer dir.close();

    var old_filename_buf: [256]u8 = undefined;
    const old_filename = std.fmt.bufPrint(&old_filename_buf, "{s}.json", .{old_name}) catch {
        try stdout.interface.print("Session name too long.\n", .{});
        return error.NameTooLong;
    };

    var new_filename_buf: [256]u8 = undefined;
    const new_filename = std.fmt.bufPrint(&new_filename_buf, "{s}.json", .{new_name}) catch {
        try stdout.interface.print("Session name too long.\n", .{});
        return error.NameTooLong;
    };

    dir.access(old_filename, .{}) catch {
        try stdout.interface.print("Session '{s}' not found.\n", .{old_name});
        return error.SessionNotFound;
    };

    dir.access(new_filename, .{}) catch |err| {
        if (err != error.FileNotFound) return err;
        dir.rename(old_filename, new_filename) catch |rename_err| {
            try stdout.interface.print("Failed to rename session: {}\n", .{rename_err});
            return rename_err;
        };
        try stdout.interface.print("Renamed session '{s}' to '{s}'.\n", .{ old_name, new_name });
        return;
    };

    try stdout.interface.print("Session '{s}' already exists.\n", .{new_name});
    return error.SessionAlreadyExists;
}

fn deleteSession(allocator: std.mem.Allocator, name: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    defer stdout.interface.flush() catch {};

    const result = getSessionsDir(allocator) catch |err| {
        if (err == error.NoSessionsFound) {
            try stdout.interface.print("Session '{s}' not found.\n", .{name});
            return error.SessionNotFound;
        }
        return err;
    };
    defer allocator.free(result.path);
    var dir = result.dir;
    defer dir.close();

    var filename_buf: [256]u8 = undefined;
    const filename = std.fmt.bufPrint(&filename_buf, "{s}.json", .{name}) catch {
        try stdout.interface.print("Session name too long.\n", .{});
        return error.NameTooLong;
    };

    dir.deleteFile(filename) catch |err| {
        if (err == error.FileNotFound) {
            try stdout.interface.print("Session '{s}' not found.\n", .{name});
            return error.SessionNotFound;
        }
        try stdout.interface.print("Failed to delete session: {}\n", .{err});
        return err;
    };

    try stdout.interface.print("Deleted session '{s}'.\n", .{name});
}

/// Connect to the prise server socket. Caller must close the returned fd.
fn connectToServer(socket_path: []const u8) !posix.fd_t {
    const sock = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch |err| {
        log.err("Failed to create socket: {}", .{err});
        return error.SocketError;
    };
    errdefer posix.close(sock);

    var addr: posix.sockaddr.un = .{ .path = undefined };
    @memcpy(addr.path[0..socket_path.len], socket_path);
    addr.path[socket_path.len] = 0;

    posix.connect(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            std.fs.File.stderr().writeAll("Server not running.\n") catch {};
            return error.ServerNotRunning;
        }
        return err;
    };

    return sock;
}

/// Send an RPC request and decode the response.
/// Skips any notification messages (type 2) that arrive before the response,
/// since the server may broadcast notifications to all clients including
/// the ephemeral connection used for this RPC.
fn sendRpcRequest(allocator: std.mem.Allocator, sock: posix.fd_t, request: []const u8) !rpc.Message {
    _ = try posix.write(sock, request);

    var response_buf: [4096]u8 = undefined;
    var buf_len: usize = 0;

    while (true) {
        const n = try posix.read(sock, response_buf[buf_len..]);
        if (n == 0) return error.NoResponse;
        buf_len += n;

        // Process all complete messages in the buffer
        while (buf_len > 0) {
            const result = rpc.decodeMessageWithSize(allocator, response_buf[0..buf_len]) catch |err| switch (err) {
                error.UnexpectedEndOfInput => break, // incomplete message, read more
                else => return err,
            };

            if (result.message == .response) return result.message;

            // Skip notification, shift remaining data
            result.message.deinit(allocator);
            const consumed = result.bytes_consumed;
            const remaining = buf_len - consumed;
            if (remaining > 0) {
                std.mem.copyForwards(u8, response_buf[0..remaining], response_buf[consumed..buf_len]);
            }
            buf_len = remaining;
        }
    }
}

/// Fetch pty_validity from the server via get_server_info RPC.
fn fetchPtyValidity(allocator: std.mem.Allocator, socket_path: []const u8) !i64 {
    const sock = try connectToServer(socket_path);
    defer posix.close(sock);

    const request = try msgpack.encode(allocator, .{ 0, 1, "get_server_info", .{} });
    defer allocator.free(request);

    const msg = try sendRpcRequest(allocator, sock, request);
    defer msg.deinit(allocator);

    if (msg != .response) return error.InvalidResponse;
    if (msg.response.err != null) return error.ServerError;
    if (msg.response.result != .map) return error.InvalidResponse;

    for (msg.response.result.map) |kv| {
        if (kv.key == .string and std.mem.eql(u8, kv.key.string, "pty_validity")) {
            if (kv.value == .integer) return kv.value.integer;
            if (kv.value == .unsigned) return @intCast(kv.value.unsigned);
        }
    }

    return error.InvalidResponse;
}

/// Spawn a detached PTY on the server via spawn_pty RPC.
/// Sends the client's full environment and cwd so the spawned shell
/// inherits PATH and other vars (matching spawnInitialPty behavior).
fn spawnDetachedPty(allocator: std.mem.Allocator, socket_path: []const u8, session_name: []const u8) !u64 {
    const sock = try connectToServer(socket_path);
    defer posix.close(sock);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Collect client environment as "KEY=VALUE" strings
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    var env_array = std.ArrayList(msgpack.Value).empty;
    defer env_array.deinit(allocator);
    var env_it = env_map.iterator();
    while (env_it.next()) |entry| {
        const env_str = try std.fmt.allocPrint(arena_alloc, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
        try env_array.append(allocator, .{ .string = env_str });
    }

    // Add PRISE_SESSION so the spawned shell knows its session name
    const session_env = try std.fmt.allocPrint(arena_alloc, "PRISE_SESSION={s}", .{session_name});
    try env_array.append(allocator, .{ .string = session_env });

    // Get client cwd
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = posix.getcwd(&cwd_buf) catch null;

    const param_count: usize = if (cwd != null) 6 else 5;
    var map_items = try allocator.alloc(msgpack.Value.KeyValue, param_count);
    defer allocator.free(map_items);
    map_items[0] = .{ .key = .{ .string = "rows" }, .value = .{ .unsigned = 24 } };
    map_items[1] = .{ .key = .{ .string = "cols" }, .value = .{ .unsigned = 80 } };
    map_items[2] = .{ .key = .{ .string = "attach" }, .value = .{ .boolean = false } };
    map_items[3] = .{ .key = .{ .string = "env" }, .value = .{ .array = env_array.items } };
    map_items[4] = .{ .key = .{ .string = "session" }, .value = .{ .string = session_name } };
    if (cwd) |c| {
        map_items[5] = .{ .key = .{ .string = "cwd" }, .value = .{ .string = c } };
    }

    const params = msgpack.Value{ .map = map_items };
    const request = try msgpack.encode(allocator, .{ 0, 1, "spawn_pty", params });
    defer allocator.free(request);

    const msg = try sendRpcRequest(allocator, sock, request);
    defer msg.deinit(allocator);

    if (msg != .response) return error.InvalidResponse;
    if (msg.response.err != null) return error.ServerError;

    // spawn_pty returns unsigned pty_id on success, string on error
    if (msg.response.result == .unsigned) return msg.response.result.unsigned;
    if (msg.response.result == .string) {
        var buf: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "error: {s}\n", .{msg.response.result.string}) catch return error.SpawnFailed;
        std.fs.File.stderr().writeAll(text) catch {};
        return error.SpawnFailed;
    }

    return error.InvalidResponse;
}

/// Write a minimal session JSON file for a single-pane detached session.
fn writeNewSessionFile(allocator: std.mem.Allocator, name: []const u8, pty_validity: i64, pty_id: u64) !void {
    const home = posix.getenv("HOME") orelse return error.NoHomeDirectory;
    const sessions_dir = try std.fs.path.join(allocator, &.{ home, ".local", "state", "prise", "sessions" });
    defer allocator.free(sessions_dir);

    // Ensure sessions directory exists (same pattern as client.zig)
    std.fs.makeDirAbsolute(sessions_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            const parent = try std.fs.path.join(allocator, &.{ home, ".local", "state", "prise" });
            defer allocator.free(parent);
            std.fs.makeDirAbsolute(parent) catch |e| {
                if (e != error.PathAlreadyExists) return e;
            };
            std.fs.makeDirAbsolute(sessions_dir) catch |e| {
                if (e != error.PathAlreadyExists) return e;
            };
        }
    };

    const json = try std.fmt.allocPrint(allocator,
        \\{{"pty_validity":{d},"tabs":[{{"id":1,"root":{{"type":"pane","id":1,"pty_id":{d}}}}}],"active_tab":1}}
    , .{ pty_validity, pty_id });
    defer allocator.free(json);

    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{name});
    defer allocator.free(filename);

    const path = try std.fs.path.join(allocator, &.{ sessions_dir, filename });
    defer allocator.free(path);

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(json);
}

/// Create a detached session: fetch server info, spawn PTY, write session file.
fn createDetachedSession(allocator: std.mem.Allocator, socket_path: []const u8, name: []const u8) !void {
    crash_context.record("detached session create name={s}", .{name});
    const pty_validity = try fetchPtyValidity(allocator, socket_path);
    const pty_id = try spawnDetachedPty(allocator, socket_path, name);
    try writeNewSessionFile(allocator, name, pty_validity, pty_id);

    var buf: [256]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    defer stdout.interface.flush() catch {};
    try stdout.interface.print("Created session '{s}'.\n", .{name});
}

fn listPtys(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    defer stdout.interface.flush() catch {};

    const sock = try connectToServer(socket_path);
    defer posix.close(sock);

    const request = try msgpack.encode(allocator, .{ 0, 1, "list_ptys", .{} });
    defer allocator.free(request);

    const msg = try sendRpcRequest(allocator, sock, request);
    defer msg.deinit(allocator);

    if (msg.response.err) |err_val| {
        const err_str = if (err_val == .string) err_val.string else "unknown error";
        try stdout.interface.print("Server error: {s}\n", .{err_str});
        return;
    }

    const result = msg.response.result;
    if (result != .map) {
        try stdout.interface.print("Invalid response format.\n", .{});
        return;
    }

    var ptys: ?[]const msgpack.Value = null;
    for (result.map) |kv| {
        if (kv.key == .string and std.mem.eql(u8, kv.key.string, "ptys")) {
            if (kv.value == .array) {
                ptys = kv.value.array;
            }
        }
    }

    if (ptys == null or ptys.?.len == 0) {
        try stdout.interface.print("No PTYs running.\n", .{});
        return;
    }

    for (ptys.?) |pty_val| {
        if (pty_val != .map) continue;

        var id: ?u64 = null;
        var cwd: []const u8 = "";
        var title: []const u8 = "";
        var clients: u64 = 0;

        for (pty_val.map) |kv| {
            if (kv.key != .string) continue;
            const key = kv.key.string;

            if (std.mem.eql(u8, key, "id")) {
                id = if (kv.value == .unsigned) kv.value.unsigned else null;
            } else if (std.mem.eql(u8, key, "cwd")) {
                cwd = if (kv.value == .string) kv.value.string else "";
            } else if (std.mem.eql(u8, key, "title")) {
                title = if (kv.value == .string) kv.value.string else "";
            } else if (std.mem.eql(u8, key, "attached_client_count")) {
                clients = if (kv.value == .unsigned) kv.value.unsigned else 0;
            }
        }

        if (id) |pty_id| {
            const title_display = if (title.len > 0) title else "(no title)";
            try stdout.interface.print("{d}: {s} [{s}] ({d} clients)\n", .{ pty_id, cwd, title_display, clients });
        }
    }
}

fn killPty(allocator: std.mem.Allocator, socket_path: []const u8, pty_id: u32) !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    defer stdout.interface.flush() catch {};

    const sock = try connectToServer(socket_path);
    defer posix.close(sock);

    const request = try msgpack.encode(allocator, .{ 0, 1, "close_pty", .{.{ "id", pty_id }} });
    defer allocator.free(request);

    const msg = try sendRpcRequest(allocator, sock, request);
    defer msg.deinit(allocator);

    if (msg.response.err) |err_val| {
        const err_str = if (err_val == .string) err_val.string else "unknown error";
        try stdout.interface.print("Server error: {s}\n", .{err_str});
        return;
    }

    if (msg.response.result == .string) {
        try stdout.interface.print("Error: {s}\n", .{msg.response.result.string});
        return;
    }

    try stdout.interface.print("PTY {d} killed.\n", .{pty_id});
}

fn findMostRecentSession(allocator: std.mem.Allocator) ![]const u8 {
    const result = getSessionsDir(allocator) catch |err| {
        if (err == error.NoSessionsFound) {
            log.err("No sessions directory found", .{});
        }
        return err;
    };
    defer allocator.free(result.path);
    var dir = result.dir;
    defer dir.close();

    var most_recent: ?[]const u8 = null;
    var most_recent_time: i128 = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const stat = dir.statFile(entry.name) catch continue;
        const mtime = stat.mtime;

        if (mtime > most_recent_time) {
            if (most_recent) |old| {
                allocator.free(old);
            }
            most_recent_time = mtime;
            const name_without_ext = entry.name[0 .. entry.name.len - 5];
            most_recent = try allocator.dupe(u8, name_without_ext);
        }
    }

    if (most_recent) |name| {
        log.info("Attaching to most recent session: {s}", .{name});
        return name;
    }

    log.err("No session files found", .{});
    return error.NoSessionsFound;
}

/// Create a minimal session JSON file so the client can switch to a new session.
/// Uses pty_validity=0 to ensure the client spawns fresh PTYs.
fn createMinimalSession(allocator: std.mem.Allocator, name: []const u8) !void {
    const result = getSessionsDir(allocator) catch |err| {
        if (err == error.NoSessionsFound) {
            // Create the sessions directory
            const home = posix.getenv("HOME") orelse return error.NoHomeDirectory;
            const state_dir = try std.fs.path.join(allocator, &.{ home, ".local", "state", "prise", "sessions" });
            defer allocator.free(state_dir);
            const parent = std.fs.path.dirname(state_dir) orelse return error.NoHomeDirectory;
            std.fs.makeDirAbsolute(parent) catch |e| {
                if (e != error.PathAlreadyExists) return e;
            };
            std.fs.makeDirAbsolute(state_dir) catch |e| {
                if (e != error.PathAlreadyExists) return e;
            };
            // Retry opening
            var dir = try std.fs.openDirAbsolute(state_dir, .{ .iterate = true });
            // Can't use getSessionsDir return type easily, just write directly
            defer dir.close();
            var filename_buf: [256]u8 = undefined;
            const filename = std.fmt.bufPrint(&filename_buf, "{s}.json", .{name}) catch return error.NameTooLong;
            const file = try dir.createFile(filename, .{});
            defer file.close();
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = posix.getcwd(&cwd_buf) catch "/tmp";
            var json_buf: [1024]u8 = undefined;
            const json = std.fmt.bufPrint(&json_buf,
                \\{{"pty_validity":0,"tabs":[{{"id":1,"root":{{"type":"pane","id":1,"pty_id":0,"cwd":{f}}}}}],"active_tab":1,"next_split_id":2,"next_tab_id":2}}
            , .{std.json.fmt(cwd, .{})}) catch return error.NameTooLong;
            try file.writeAll(json);
            return;
        }
        return err;
    };
    defer allocator.free(result.path);
    var dir = result.dir;
    defer dir.close();

    var filename_buf: [256]u8 = undefined;
    const filename = std.fmt.bufPrint(&filename_buf, "{s}.json", .{name}) catch return error.NameTooLong;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = posix.getcwd(&cwd_buf) catch "/tmp";

    var json_buf: [1024]u8 = undefined;
    const json = std.fmt.bufPrint(&json_buf,
        \\{{"pty_validity":0,"tabs":[{{"id":1,"root":{{"type":"pane","id":1,"pty_id":0,"cwd":{f}}}}}],"active_tab":1,"next_split_id":2,"next_tab_id":2}}
    , .{std.json.fmt(cwd, .{})}) catch return error.NameTooLong;

    const file = try dir.createFile(filename, .{});
    defer file.close();
    try file.writeAll(json);
}

/// Send a session_switch RPC to the server, which notifies the client
/// owning the given PTY to switch to the target session.
fn requestNestedSessionSwitch(allocator: std.mem.Allocator, socket_path: []const u8, session_name: []const u8, pty_id: u32) !void {
    crash_context.record("nested session switch target={s} pty_id={d}", .{ session_name, pty_id });
    const sock = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch |err| {
        log.err("Failed to create socket: {}", .{err});
        return error.SocketError;
    };
    defer posix.close(sock);

    var addr: posix.sockaddr.un = .{ .path = undefined };
    @memcpy(addr.path[0..socket_path.len], socket_path);
    addr.path[socket_path.len] = 0;

    posix.connect(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            return error.ServerNotRunning;
        }
        return err;
    };

    // Build session_switch RPC: [0, msgid, "session_switch", {pty_id: <id>, session: "<name>"}]
    var map_items: [2]msgpack.Value.KeyValue = .{
        .{ .key = .{ .string = "pty_id" }, .value = .{ .unsigned = pty_id } },
        .{ .key = .{ .string = "session" }, .value = .{ .string = session_name } },
    };
    var msg_items: [4]msgpack.Value = .{
        .{ .unsigned = 0 },
        .{ .unsigned = 1 },
        .{ .string = "session_switch" },
        .{ .map = &map_items },
    };

    const request = try msgpack.encodeFromValue(allocator, .{ .array = &msg_items });
    defer allocator.free(request);

    _ = try posix.write(sock, request);

    // Read response
    var response_buf: [16384]u8 = undefined;
    const n = try posix.read(sock, &response_buf);
    if (n == 0) return error.NoResponse;

    const response = rpc.decodeMessage(allocator, response_buf[0..n]) catch return error.DecodeError;
    defer response.deinit(allocator);

    if (response != .response) return error.UnexpectedResponse;
    if (response.response.err) |err_val| {
        if (err_val == .string) {
            log.err("Server error: {s}", .{err_val.string});
        }
        return error.ServerError;
    }

    // String result indicates an application-level error
    if (response.response.result == .string) {
        var err_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&err_buf, "error: {s}\n", .{response.response.result.string}) catch return error.SessionSwitchFailed;
        std.fs.File.stderr().writeAll(msg) catch {};
        return error.SessionSwitchFailed;
    }
}

const testing = std.testing;

const TestSessionsDir = struct {
    tmp: testing.TmpDir,
    home_path: []const u8,
    sessions_path: []const u8,

    fn init(allocator: std.mem.Allocator) !TestSessionsDir {
        var tmp = testing.tmpDir(.{});
        const home_path = try tmp.parent_dir.realpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(home_path);

        const relative_sessions_path = try std.fmt.allocPrint(
            allocator,
            "{s}/.local/state/prise/sessions",
            .{tmp.sub_path},
        );
        defer allocator.free(relative_sessions_path);

        try tmp.parent_dir.makePath(relative_sessions_path);

        const sessions_path = try std.fs.path.join(
            allocator,
            &.{ home_path, ".local", "state", "prise", "sessions" },
        );
        errdefer allocator.free(sessions_path);

        return .{
            .tmp = tmp,
            .home_path = home_path,
            .sessions_path = sessions_path,
        };
    }

    fn deinit(self: *TestSessionsDir, allocator: std.mem.Allocator) void {
        allocator.free(self.home_path);
        allocator.free(self.sessions_path);
        self.tmp.cleanup();
    }
};

const RenameTestServer = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    response_bytes: []const u8,
    request_bytes: ?[]u8 = null,
    run_error: ?anyerror = null,
    thread: ?std.Thread = null,

    fn start(self: *RenameTestServer) !void {
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    fn join(self: *RenameTestServer) !void {
        const thread = self.thread orelse return;
        thread.join();
        self.thread = null;
        if (self.run_error) |err| return err;
    }

    fn deinit(self: *RenameTestServer) void {
        if (self.request_bytes) |request_bytes| self.allocator.free(request_bytes);
        self.allocator.free(self.response_bytes);
    }

    fn threadMain(self: *RenameTestServer) void {
        self.run() catch |err| {
            self.run_error = err;
        };
    }

    fn run(self: *RenameTestServer) !void {
        posix.unlink(self.socket_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        const listen_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        defer posix.close(listen_fd);
        defer posix.unlink(self.socket_path) catch {};

        var addr: posix.sockaddr.un = undefined;
        addr.family = posix.AF.UNIX;
        @memcpy(addr.path[0..self.socket_path.len], self.socket_path);
        addr.path[self.socket_path.len] = 0;

        try posix.bind(listen_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        try posix.listen(listen_fd, 1);

        const conn_fd = try posix.accept(listen_fd, null, null, 0);
        defer posix.close(conn_fd);

        var request_buf: [4096]u8 = undefined;
        const n = try posix.read(conn_fd, &request_buf);
        if (n == 0) return error.NoRequest;

        self.request_bytes = try self.allocator.dupe(u8, request_buf[0..n]);
        _ = try posix.write(conn_fd, self.response_bytes);
    }
};

fn writeSessionFile(
    allocator: std.mem.Allocator,
    sessions_path: []const u8,
    session_name: []const u8,
    json: []const u8,
) !void {
    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{session_name});
    defer allocator.free(file_name);

    const session_path = try std.fs.path.join(allocator, &.{ sessions_path, file_name });
    defer allocator.free(session_path);

    const file = try std.fs.createFileAbsolute(session_path, .{});
    defer file.close();
    try file.writeAll(json);
}

fn readSessionFile(
    allocator: std.mem.Allocator,
    sessions_path: []const u8,
    session_name: []const u8,
) ![]u8 {
    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{session_name});
    defer allocator.free(file_name);

    const session_path = try std.fs.path.join(allocator, &.{ sessions_path, file_name });
    defer allocator.free(session_path);

    const file = try std.fs.openFileAbsolute(session_path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, 1024 * 1024);
}

fn expectSavedTabTitle(json: []const u8, expected_title: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const tabs = parsed.value.object.get("tabs").?.array.items;
    try testing.expectEqualStrings(expected_title, tabs[0].object.get("title").?.string);
}

fn expectRenameRequest(request_bytes: []const u8, expected_pty_id: u32, expected_validity: i64, expected_title: []const u8) !void {
    const msg = try rpc.decodeMessage(testing.allocator, request_bytes);
    defer msg.deinit(testing.allocator);

    try testing.expect(msg == .request);
    try testing.expectEqualStrings("rename_tab", msg.request.method);

    var pty_id: ?u32 = null;
    var pty_validity: ?i64 = null;
    var title: ?[]const u8 = null;

    for (msg.request.params.map) |kv| {
        if (kv.key != .string) continue;
        if (std.mem.eql(u8, kv.key.string, "pty_id")) {
            pty_id = switch (kv.value) {
                .unsigned => |value| @intCast(value),
                .integer => |value| @intCast(value),
                else => null,
            };
        } else if (std.mem.eql(u8, kv.key.string, "pty_validity")) {
            pty_validity = switch (kv.value) {
                .integer => |value| value,
                .unsigned => |value| @intCast(value),
                else => null,
            };
        } else if (std.mem.eql(u8, kv.key.string, "title")) {
            title = if (kv.value == .string) kv.value.string else null;
        }
    }

    try testing.expectEqual(expected_pty_id, pty_id.?);
    try testing.expectEqual(expected_validity, pty_validity.?);
    try testing.expectEqualStrings(expected_title, title.?);
}

fn waitForSocketPath(socket_path: []const u8) !void {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        std.fs.accessAbsolute(socket_path, .{}) catch {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        return;
    }

    return error.SocketStartupTimeout;
}

test "executeTabRename persists saved title after acknowledged RPC" {
    var sessions_dir = try TestSessionsDir.init(testing.allocator);
    defer sessions_dir.deinit(testing.allocator);

    try writeSessionFile(testing.allocator, sessions_dir.sessions_path, "demo",
        \\{"tabs":[{"id":1,"title":"old","root":{"type":"pane","id":10,"pty_id":42}}],"active_tab":1}
    );

    const socket_path = try std.fs.path.join(testing.allocator, &.{ sessions_dir.home_path, "rename.sock" });
    defer testing.allocator.free(socket_path);

    var test_server: RenameTestServer = .{
        .allocator = testing.allocator,
        .socket_path = socket_path,
        .response_bytes = try msgpack.encode(testing.allocator, .{ 1, 1, null, "ok" }),
    };
    defer test_server.deinit();

    try test_server.start();
    defer test_server.join() catch {};
    try waitForSocketPath(socket_path);

    try executeTabRename(
        testing.allocator,
        socket_path,
        sessions_dir.sessions_path,
        .{ .session_name = "demo", .pty_id = 42, .pty_validity = 1234 },
        "renamed",
    );
    try test_server.join();

    const updated = try readSessionFile(testing.allocator, sessions_dir.sessions_path, "demo");
    defer testing.allocator.free(updated);
    try expectSavedTabTitle(updated, "renamed");
    try expectRenameRequest(test_server.request_bytes.?, 42, 1234, "renamed");
}

test "executeTabRename leaves session json unchanged on rejected RPC" {
    var sessions_dir = try TestSessionsDir.init(testing.allocator);
    defer sessions_dir.deinit(testing.allocator);

    try writeSessionFile(testing.allocator, sessions_dir.sessions_path, "demo",
        \\{"tabs":[{"id":1,"title":"old","root":{"type":"pane","id":10,"pty_id":42}}],"active_tab":1}
    );

    const socket_path = try std.fs.path.join(testing.allocator, &.{ sessions_dir.home_path, "rename.sock" });
    defer testing.allocator.free(socket_path);

    var test_server: RenameTestServer = .{
        .allocator = testing.allocator,
        .socket_path = socket_path,
        .response_bytes = try msgpack.encode(
            testing.allocator,
            .{ 1, 1, null, "stale shell environment; open a new shell" },
        ),
    };
    defer test_server.deinit();

    try test_server.start();
    defer test_server.join() catch {};
    try waitForSocketPath(socket_path);

    try testing.expectError(
        error.RenameRejected,
        executeTabRename(
            testing.allocator,
            socket_path,
            sessions_dir.sessions_path,
            .{ .session_name = "demo", .pty_id = 42, .pty_validity = 5678 },
            "renamed",
        ),
    );
    try test_server.join();

    const updated = try readSessionFile(testing.allocator, sessions_dir.sessions_path, "demo");
    defer testing.allocator.free(updated);
    try expectSavedTabTitle(updated, "old");
}

// Note: parseArgs cannot be unit-tested without refactoring to accept
// an argument iterator instead of calling std.process.argsWithAllocator.

test "ParseResult defaults" {
    const result: ParseResult = .{};
    try std.testing.expect(result.detached == false);
    try std.testing.expect(result.attach_session == null);
    try std.testing.expect(result.new_session_name == null);
}

test "validateSessionName accepts valid names" {
    try validateSessionName("my-session");
    try validateSessionName("session_1");
    try validateSessionName("abc123");
    try validateSessionName("a");
    try validateSessionName("A-Z_0-9");
}

test "validateSessionName rejects empty name" {
    try std.testing.expectError(error.SessionNameEmpty, validateSessionName(""));
}

test "validateSessionName rejects names over 64 chars" {
    const long_name = "a" ** 65;
    try std.testing.expectError(error.SessionNameTooLong, validateSessionName(long_name));
}

test "validateSessionName rejects invalid characters" {
    try std.testing.expectError(error.SessionNameInvalid, validateSessionName("has space"));
    try std.testing.expectError(error.SessionNameInvalid, validateSessionName("has/slash"));
    try std.testing.expectError(error.SessionNameInvalid, validateSessionName("has.dot"));
    try std.testing.expectError(error.SessionNameInvalid, validateSessionName("has@at"));
}

test {
    _ = @import("io/mock.zig");
    _ = @import("server.zig");
    _ = @import("session_json.zig");
    _ = @import("msgpack.zig");
    _ = @import("rpc.zig");
    _ = @import("pty.zig");
    _ = @import("client.zig");
    _ = @import("redraw.zig");
    _ = @import("Surface.zig");
    _ = @import("ui.zig");
    _ = @import("widget.zig");
    _ = @import("TextInput.zig");
    _ = @import("ui.zig");
    _ = @import("tui_test.zig");
    _ = @import("key_encode.zig");
    _ = @import("mouse_encode.zig");
    _ = @import("vaxis_helper.zig");
    _ = @import("lua_test.zig");
    _ = @import("key_string.zig");
    _ = @import("action.zig");
    _ = @import("keybind.zig");
    _ = @import("keybind_compiler.zig");
    _ = @import("keybind_matcher.zig");
    _ = @import("lua_msgpack.zig");
    _ = @import("crash_context.zig");

    if (builtin.os.tag.isDarwin() or builtin.os.tag.isBSD()) {
        _ = @import("io/kqueue.zig");
    } else if (builtin.os.tag == .linux) {
        _ = @import("io/io_uring.zig");
    }
}
