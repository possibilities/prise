//! Strict TOML parser for ~/.config/prise/prise.toml.
//!
//! Returns one PlugDecl per `[[plug]]` block. Pure: no Server access, no I/O —
//! caller reads the file, hands us the bytes, we hand back validated decls.
//!
//! Strict by design: unknown keys, malformed types, non-absolute cmd[0],
//! duplicate names, and oversized fields are all rejected with a typed error.
//! The server logs FATAL on any error and refuses to start; launchd's
//! ThrottleInterval (10s default) is the circuit breaker.

const std = @import("std");
const toml = @import("toml");

/// Mirror of LIMITS.PLUG_NAME_MAX in server.zig. Kept in sync manually so
/// this module doesn't take a server.zig import dependency.
const PLUG_NAME_MAX: usize = 64;
/// Mirror of LIMITS.SPAWN_ARGV_MAX in server.zig.
const SPAWN_ARGV_MAX: usize = 64;

/// One validated `[[plug]]` block. The slices are arena-owned by the caller's
/// allocator; freeing them is the caller's responsibility (use deinitDecls).
pub const PlugDecl = struct {
    name: []const u8,
    cmd: []const []const u8,
    restart: bool,
    restart_delay_ms: u32,
};

pub const ParseError = error{
    InvalidToml,
    InvalidPlugBlock,
    InvalidPlugName,
    InvalidPlugCmd,
    DuplicatePlugName,
    UnknownPlugKey,
    OutOfMemory,
};

const ALLOWED_KEYS = [_][]const u8{
    "name",
    "cmd",
    "restart",
    "restart_delay_ms",
};

const ROOT_ALLOWED_KEYS = [_][]const u8{"plug"};

/// Parse a TOML document and return one PlugDecl per `[[plug]]` block.
/// Empty input or no `[[plug]]` blocks → empty slice (server starts clean).
/// Caller owns the returned slice and must call deinitDecls to free.
pub fn parsePlugConfig(allocator: std.mem.Allocator, content: []const u8) ParseError![]PlugDecl {
    if (content.len == 0) return allocator.alloc(PlugDecl, 0);

    var parser = toml.Parser(toml.Table).init(allocator);
    defer parser.deinit();

    var parsed = parser.parseString(content) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidToml,
    };
    defer parsed.deinit();

    return parsePlugBlocks(allocator, &parsed.value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |e| return e,
    };
}

/// Free a slice returned by parsePlugConfig.
pub fn deinitDecls(allocator: std.mem.Allocator, decls: []PlugDecl) void {
    for (decls) |d| {
        allocator.free(d.name);
        for (d.cmd) |arg| allocator.free(arg);
        allocator.free(d.cmd);
    }
    allocator.free(decls);
}

fn parsePlugBlocks(allocator: std.mem.Allocator, root: *toml.Table) ParseError![]PlugDecl {
    var it = root.iterator();
    while (it.next()) |entry| {
        if (!isAllowedRootKey(entry.key_ptr.*)) {
            return error.UnknownPlugKey;
        }
    }

    const plug_value = root.get("plug") orelse return allocator.alloc(PlugDecl, 0);
    if (plug_value != .array) return error.InvalidPlugBlock;
    const blocks = plug_value.array.items;
    if (blocks.len == 0) return allocator.alloc(PlugDecl, 0);

    var decls = try allocator.alloc(PlugDecl, blocks.len);
    var built: usize = 0;
    errdefer {
        for (decls[0..built]) |d| {
            allocator.free(d.name);
            for (d.cmd) |arg| allocator.free(arg);
            allocator.free(d.cmd);
        }
        allocator.free(decls);
    }

    for (blocks) |block| {
        if (block != .table) return error.InvalidPlugBlock;
        decls[built] = try parseOneBlock(allocator, block.table);
        built += 1;
    }

    try assertUniqueNames(decls);
    return decls;
}

fn parseOneBlock(allocator: std.mem.Allocator, table: *toml.Table) ParseError!PlugDecl {
    var it = table.iterator();
    while (it.next()) |entry| {
        if (!isAllowedKey(entry.key_ptr.*)) return error.UnknownPlugKey;
    }

    const name_val = table.get("name") orelse return error.InvalidPlugBlock;
    if (name_val != .string) return error.InvalidPlugName;
    const name_src = name_val.string;
    if (!isValidPlugName(name_src)) return error.InvalidPlugName;

    const cmd_val = table.get("cmd") orelse return error.InvalidPlugBlock;
    if (cmd_val != .array) return error.InvalidPlugCmd;
    const cmd_items = cmd_val.array.items;
    if (cmd_items.len == 0 or cmd_items.len > SPAWN_ARGV_MAX) return error.InvalidPlugCmd;
    if (cmd_items[0] != .string or !std.fs.path.isAbsolute(cmd_items[0].string)) {
        return error.InvalidPlugCmd;
    }
    for (cmd_items) |arg| {
        if (arg != .string) return error.InvalidPlugCmd;
    }

    const restart: bool = if (table.get("restart")) |v| blk: {
        if (v != .boolean) return error.InvalidPlugBlock;
        break :blk v.boolean;
    } else false;

    const restart_delay_ms: u32 = if (table.get("restart_delay_ms")) |v| blk: {
        if (v != .integer) return error.InvalidPlugBlock;
        if (v.integer < 0) return error.InvalidPlugBlock;
        break :blk std.math.cast(u32, v.integer) orelse 1000;
    } else 1000;

    const owned_name = try allocator.dupe(u8, name_src);
    errdefer allocator.free(owned_name);

    const owned_cmd = try allocator.alloc([]const u8, cmd_items.len);
    var built: usize = 0;
    errdefer {
        for (owned_cmd[0..built]) |arg| allocator.free(arg);
        allocator.free(owned_cmd);
    }
    for (cmd_items) |arg| {
        owned_cmd[built] = try allocator.dupe(u8, arg.string);
        built += 1;
    }

    return .{
        .name = owned_name,
        .cmd = owned_cmd,
        .restart = restart,
        .restart_delay_ms = restart_delay_ms,
    };
}

fn isAllowedRootKey(key: []const u8) bool {
    for (ROOT_ALLOWED_KEYS) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

fn isAllowedKey(key: []const u8) bool {
    for (ALLOWED_KEYS) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

fn isValidPlugName(name: []const u8) bool {
    if (name.len == 0 or name.len > PLUG_NAME_MAX) return false;
    for (name) |c| {
        if (c == '/' or c == ' ' or c == '\t' or c == '\n' or c == '\r') return false;
    }
    return true;
}

fn assertUniqueNames(decls: []const PlugDecl) ParseError!void {
    var i: usize = 0;
    while (i < decls.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < decls.len) : (j += 1) {
            if (std.mem.eql(u8, decls[i].name, decls[j].name)) return error.DuplicatePlugName;
        }
    }
}

// ---- tests ----------------------------------------------------------------

test "parsePlugConfig - empty content returns empty list" {
    const decls = try parsePlugConfig(std.testing.allocator, "");
    defer deinitDecls(std.testing.allocator, decls);
    try std.testing.expectEqual(@as(usize, 0), decls.len);
}

test "parsePlugConfig - no plug blocks returns empty list" {
    const decls = try parsePlugConfig(std.testing.allocator, "# no plugs here\n");
    defer deinitDecls(std.testing.allocator, decls);
    try std.testing.expectEqual(@as(usize, 0), decls.len);
}

test "parsePlugConfig - happy path single block" {
    const src =
        \\[[plug]]
        \\name = "control-plug"
        \\cmd = ["/usr/local/bin/control-plug", "--verbose"]
        \\restart = true
        \\restart_delay_ms = 500
        \\
    ;
    const decls = try parsePlugConfig(std.testing.allocator, src);
    defer deinitDecls(std.testing.allocator, decls);

    try std.testing.expectEqual(@as(usize, 1), decls.len);
    try std.testing.expectEqualStrings("control-plug", decls[0].name);
    try std.testing.expectEqual(@as(usize, 2), decls[0].cmd.len);
    try std.testing.expectEqualStrings("/usr/local/bin/control-plug", decls[0].cmd[0]);
    try std.testing.expectEqualStrings("--verbose", decls[0].cmd[1]);
    try std.testing.expect(decls[0].restart);
    try std.testing.expectEqual(@as(u32, 500), decls[0].restart_delay_ms);
}

test "parsePlugConfig - defaults applied when restart fields absent" {
    const src =
        \\[[plug]]
        \\name = "p"
        \\cmd = ["/bin/true"]
        \\
    ;
    const decls = try parsePlugConfig(std.testing.allocator, src);
    defer deinitDecls(std.testing.allocator, decls);

    try std.testing.expectEqual(@as(usize, 1), decls.len);
    try std.testing.expect(!decls[0].restart);
    try std.testing.expectEqual(@as(u32, 1000), decls[0].restart_delay_ms);
}

test "parsePlugConfig - multiple blocks" {
    const src =
        \\[[plug]]
        \\name = "a"
        \\cmd = ["/bin/a"]
        \\
        \\[[plug]]
        \\name = "b"
        \\cmd = ["/bin/b"]
        \\restart = true
        \\
    ;
    const decls = try parsePlugConfig(std.testing.allocator, src);
    defer deinitDecls(std.testing.allocator, decls);

    try std.testing.expectEqual(@as(usize, 2), decls.len);
    try std.testing.expectEqualStrings("a", decls[0].name);
    try std.testing.expectEqualStrings("b", decls[1].name);
    try std.testing.expect(decls[1].restart);
}

test "parsePlugConfig - malformed TOML rejected" {
    const src =
        \\[[plug
        \\name = "broken"
        \\
    ;
    try std.testing.expectError(error.InvalidToml, parsePlugConfig(std.testing.allocator, src));
}

test "parsePlugConfig - unknown key in plug block rejected" {
    const src =
        \\[[plug]]
        \\name = "p"
        \\cmd = ["/bin/p"]
        \\restart_dely_ms = 500
        \\
    ;
    try std.testing.expectError(error.UnknownPlugKey, parsePlugConfig(std.testing.allocator, src));
}

test "parsePlugConfig - unknown root key rejected" {
    const src =
        \\unexpected = "value"
        \\
        \\[[plug]]
        \\name = "p"
        \\cmd = ["/bin/p"]
        \\
    ;
    try std.testing.expectError(error.UnknownPlugKey, parsePlugConfig(std.testing.allocator, src));
}

test "parsePlugConfig - non-absolute cmd[0] rejected" {
    const src =
        \\[[plug]]
        \\name = "p"
        \\cmd = ["bin/p"]
        \\
    ;
    try std.testing.expectError(error.InvalidPlugCmd, parsePlugConfig(std.testing.allocator, src));
}

test "parsePlugConfig - empty cmd array rejected" {
    const src =
        \\[[plug]]
        \\name = "p"
        \\cmd = []
        \\
    ;
    try std.testing.expectError(error.InvalidPlugCmd, parsePlugConfig(std.testing.allocator, src));
}

test "parsePlugConfig - duplicate name rejected" {
    const src =
        \\[[plug]]
        \\name = "dup"
        \\cmd = ["/bin/a"]
        \\
        \\[[plug]]
        \\name = "dup"
        \\cmd = ["/bin/b"]
        \\
    ;
    try std.testing.expectError(error.DuplicatePlugName, parsePlugConfig(std.testing.allocator, src));
}

test "parsePlugConfig - empty name rejected" {
    const src =
        \\[[plug]]
        \\name = ""
        \\cmd = ["/bin/p"]
        \\
    ;
    try std.testing.expectError(error.InvalidPlugName, parsePlugConfig(std.testing.allocator, src));
}

test "parsePlugConfig - name with slash rejected" {
    const src =
        \\[[plug]]
        \\name = "bad/name"
        \\cmd = ["/bin/p"]
        \\
    ;
    try std.testing.expectError(error.InvalidPlugName, parsePlugConfig(std.testing.allocator, src));
}

test "parsePlugConfig - name with whitespace rejected" {
    const src =
        \\[[plug]]
        \\name = "bad name"
        \\cmd = ["/bin/p"]
        \\
    ;
    try std.testing.expectError(error.InvalidPlugName, parsePlugConfig(std.testing.allocator, src));
}

test "parsePlugConfig - oversized name rejected" {
    // 65 chars (PLUG_NAME_MAX = 64)
    const src =
        \\[[plug]]
        \\name = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\cmd = ["/bin/p"]
        \\
    ;
    try std.testing.expectError(error.InvalidPlugName, parsePlugConfig(std.testing.allocator, src));
}

test "parsePlugConfig - missing name rejected" {
    const src =
        \\[[plug]]
        \\cmd = ["/bin/p"]
        \\
    ;
    try std.testing.expectError(error.InvalidPlugBlock, parsePlugConfig(std.testing.allocator, src));
}

test "parsePlugConfig - missing cmd rejected" {
    const src =
        \\[[plug]]
        \\name = "p"
        \\
    ;
    try std.testing.expectError(error.InvalidPlugBlock, parsePlugConfig(std.testing.allocator, src));
}

test "parsePlugConfig - cmd with non-string element rejected" {
    const src =
        \\[[plug]]
        \\name = "p"
        \\cmd = ["/bin/p", 42]
        \\
    ;
    try std.testing.expectError(error.InvalidPlugCmd, parsePlugConfig(std.testing.allocator, src));
}

test "parsePlugConfig - negative restart_delay_ms rejected" {
    const src =
        \\[[plug]]
        \\name = "p"
        \\cmd = ["/bin/p"]
        \\restart_delay_ms = -1
        \\
    ;
    try std.testing.expectError(error.InvalidPlugBlock, parsePlugConfig(std.testing.allocator, src));
}
