//! Bidirectional conversion between msgpack.Value and Lua stack values.
//!
//! Provides the bridge between the msgpack-RPC wire format used by plugs
//! and the Lua scripting environment. All plug data passes through these
//! two functions.

const std = @import("std");
const ziglua = @import("zlua");
const msgpack = @import("msgpack.zig");

const Allocator = std.mem.Allocator;
const Lua = ziglua.Lua;
const log = std.log.scoped(.lua_msgpack);

/// Recursion depth limit to prevent stack overflow from deeply nested structures.
/// 16 levels is generous for any reasonable config data while protecting against
/// malicious or buggy plug output.
const DEPTH_LIMIT: usize = 16;

/// Push a msgpack Value onto the Lua stack as the equivalent Lua type.
/// Pushes nil if depth limit is exceeded.
pub fn pushMsgpackValue(lua: *Lua, value: msgpack.Value) void {
    pushMsgpackValueDepth(lua, value, 0);
}

fn pushMsgpackValueDepth(lua: *Lua, value: msgpack.Value, depth: usize) void {
    if (depth >= DEPTH_LIMIT) {
        log.warn("depth limit exceeded, pushing nil", .{});
        lua.pushNil();
        return;
    }

    switch (value) {
        .nil => lua.pushNil(),
        .boolean => |b| lua.pushBoolean(b),
        .integer => |i| lua.pushInteger(@intCast(i)),
        .unsigned => |u| {
            // Lua integers are i64; large u64 values lose precision but this
            // is the same trade-off neovim makes with msgpack-rpc.
            if (u <= std.math.maxInt(i64)) {
                lua.pushInteger(@intCast(u));
            } else {
                lua.pushNumber(@floatFromInt(u));
            }
        },
        .float => |f| lua.pushNumber(f),
        .string, .binary => |s| {
            // Lua strings are 8-bit clean, so binary data maps directly
            _ = lua.pushString(s);
        },
        .array => |arr| {
            lua.createTable(@intCast(arr.len), 0);
            for (arr, 1..) |item, i| {
                pushMsgpackValueDepth(lua, item, depth + 1);
                lua.rawSetIndex(-2, @intCast(i));
            }
        },
        .map => |m| {
            lua.createTable(0, @intCast(m.len));
            for (m) |kv| {
                pushMsgpackValueDepth(lua, kv.key, depth + 1);
                pushMsgpackValueDepth(lua, kv.value, depth + 1);
                lua.setTable(-3);
            }
        },
    }
}

pub const ConvertError = error{
    DepthLimitExceeded,
    UnsupportedType,
} || Allocator.Error;

/// Convert a Lua stack value at the given index to a msgpack.Value.
/// The returned value is heap-allocated and owned by the caller.
pub fn luaToMsgpackValue(
    lua: *Lua,
    allocator: Allocator,
    index: i32,
) ConvertError!msgpack.Value {
    return luaToMsgpackValueDepth(lua, allocator, index, 0);
}

fn luaToMsgpackValueDepth(
    lua: *Lua,
    allocator: Allocator,
    index: i32,
    depth: usize,
) ConvertError!msgpack.Value {
    if (depth >= DEPTH_LIMIT) return error.DepthLimitExceeded;

    // Normalize negative indices to absolute (Lua convention)
    const abs_index = if (index < 0)
        lua.getTop() + index + 1
    else
        index;

    switch (lua.typeOf(abs_index)) {
        .nil, .none => return .nil,
        .boolean => return .{ .boolean = lua.toBoolean(abs_index) },
        .number => {
            if (lua.isInteger(abs_index)) {
                const i = lua.toInteger(abs_index) catch
                    return .{ .integer = 0 };
                return .{ .integer = i };
            } else {
                const n = lua.toNumber(abs_index) catch
                    return .{ .float = 0.0 };
                return .{ .float = n };
            }
        },
        .string => {
            const s = lua.toString(abs_index) catch return .nil;
            const duped = try allocator.dupe(u8, s);
            return .{ .string = duped };
        },
        .table => return try luaTableToMsgpack(
            lua,
            allocator,
            abs_index,
            depth,
        ),
        else => return error.UnsupportedType,
    }
}

fn luaTableToMsgpack(
    lua: *Lua,
    allocator: Allocator,
    index: i32,
    depth: usize,
) ConvertError!msgpack.Value {
    const raw_len = lua.rawLen(index);

    // Empty table → empty array (convention: matches neovim behavior)
    if (raw_len == 0 and !hasNonSequentialKeys(lua, index)) {
        const empty = try allocator.alloc(msgpack.Value, 0);
        return .{ .array = empty };
    }

    // Pure sequence (keys 1..N with no gaps) → array
    if (raw_len > 0 and !hasNonSequentialKeys(lua, index)) {
        return try luaSequenceToArray(lua, allocator, index, raw_len, depth);
    }

    // Mixed or non-sequential keys → map
    return try luaTableToMap(lua, allocator, index, depth);
}

/// Check if a table has any keys beyond the sequential 1..rawLen range.
fn hasNonSequentialKeys(lua: *Lua, index: i32) bool {
    const raw_len = lua.rawLen(index);
    lua.pushNil();
    var count: usize = 0;
    while (lua.next(index)) {
        lua.pop(1); // pop value, keep key
        count += 1;
        if (count > raw_len) {
            lua.pop(1); // pop remaining key
            return true;
        }
    }
    return count != raw_len;
}

fn luaSequenceToArray(
    lua: *Lua,
    allocator: Allocator,
    index: i32,
    len: usize,
    depth: usize,
) ConvertError!msgpack.Value {
    const arr = try allocator.alloc(msgpack.Value, len);
    var i: usize = 0;
    errdefer {
        for (arr[0..i]) |item| item.deinit(allocator);
        allocator.free(arr);
    }

    while (i < len) : (i += 1) {
        _ = lua.rawGetIndex(index, @intCast(i + 1));
        errdefer lua.pop(1);
        arr[i] = try luaToMsgpackValueDepth(lua, allocator, -1, depth + 1);
        lua.pop(1);
    }

    return .{ .array = arr };
}

fn luaTableToMap(
    lua: *Lua,
    allocator: Allocator,
    index: i32,
    depth: usize,
) ConvertError!msgpack.Value {
    // First pass: count entries
    var count: usize = 0;
    lua.pushNil();
    while (lua.next(index)) {
        lua.pop(1);
        count += 1;
    }

    const entries = try allocator.alloc(msgpack.Value.KeyValue, count);
    @memset(entries, .{ .key = .nil, .value = .nil });
    var i: usize = 0;
    errdefer {
        for (entries[0..i]) |kv| {
            kv.key.deinit(allocator);
            kv.value.deinit(allocator);
        }
        allocator.free(entries);
    }

    lua.pushNil();
    while (lua.next(index)) {
        // Stack: key at -2, value at -1
        // Pop both on error so caller gets a clean stack
        errdefer lua.pop(2);
        entries[i].value = try luaToMsgpackValueDepth(
            lua,
            allocator,
            -1,
            depth + 1,
        );
        errdefer entries[i].value.deinit(allocator);
        entries[i].key = try luaToMsgpackValueDepth(
            lua,
            allocator,
            -2,
            depth + 1,
        );
        i += 1;
        lua.pop(1); // pop value, keep key for next iteration
    }

    return .{ .map = entries };
}

// -- Tests ------------------------------------------------------------------

const testing = std.testing;

test "pushMsgpackValue nil" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    pushMsgpackValue(lua, .nil);
    try testing.expect(lua.typeOf(-1) == .nil);
}

test "pushMsgpackValue boolean" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    pushMsgpackValue(lua, .{ .boolean = true });
    try testing.expect(lua.toBoolean(-1) == true);
}

test "pushMsgpackValue integer" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    pushMsgpackValue(lua, .{ .integer = -42 });
    const i = lua.toInteger(-1) catch unreachable;
    try testing.expectEqual(@as(i64, -42), i);
}

test "pushMsgpackValue unsigned fits i64" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    pushMsgpackValue(lua, .{ .unsigned = 100 });
    const i = lua.toInteger(-1) catch unreachable;
    try testing.expectEqual(@as(i64, 100), i);
}

test "pushMsgpackValue float" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    pushMsgpackValue(lua, .{ .float = 3.14 });
    const n = lua.toNumber(-1) catch unreachable;
    try testing.expectApproxEqAbs(@as(f64, 3.14), n, 0.001);
}

test "pushMsgpackValue string" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    pushMsgpackValue(lua, .{ .string = "hello" });
    const s = lua.toString(-1) catch unreachable;
    try testing.expectEqualStrings("hello", s);
}

test "pushMsgpackValue binary" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    pushMsgpackValue(lua, .{ .binary = &[_]u8{ 0x00, 0xff, 0x42 } });
    const s = lua.toString(-1) catch unreachable;
    try testing.expectEqual(@as(usize, 3), s.len);
    try testing.expectEqual(@as(u8, 0x00), s[0]);
    try testing.expectEqual(@as(u8, 0xff), s[1]);
    try testing.expectEqual(@as(u8, 0x42), s[2]);
}

test "pushMsgpackValue array" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    var items = [_]msgpack.Value{
        .{ .integer = 1 },
        .{ .integer = 2 },
        .{ .integer = 3 },
    };
    pushMsgpackValue(lua, .{ .array = &items });

    try testing.expect(lua.typeOf(-1) == .table);
    try testing.expectEqual(@as(usize, 3), lua.rawLen(-1));
}

test "pushMsgpackValue map" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    var kvs = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "name" }, .value = .{ .string = "test" } },
    };
    pushMsgpackValue(lua, .{ .map = &kvs });

    try testing.expect(lua.typeOf(-1) == .table);
    _ = lua.getField(-1, "name");
    const s = lua.toString(-1) catch unreachable;
    try testing.expectEqualStrings("test", s);
}

test "pushMsgpackValue empty array" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    var empty = [_]msgpack.Value{};
    pushMsgpackValue(lua, .{ .array = &empty });
    try testing.expect(lua.typeOf(-1) == .table);
    try testing.expectEqual(@as(usize, 0), lua.rawLen(-1));
}

test "pushMsgpackValue depth limit produces nil" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    pushMsgpackValueDepth(lua, .{ .integer = 42 }, DEPTH_LIMIT);
    try testing.expect(lua.typeOf(-1) == .nil);
}

test "luaToMsgpackValue nil" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    lua.pushNil();
    const val = try luaToMsgpackValue(lua, testing.allocator, -1);
    try testing.expect(val == .nil);
}

test "luaToMsgpackValue integer" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    lua.pushInteger(42);
    const val = try luaToMsgpackValue(lua, testing.allocator, -1);
    try testing.expectEqual(@as(i64, 42), val.integer);
}

test "luaToMsgpackValue string" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    _ = lua.pushString("world");
    const val = try luaToMsgpackValue(lua, testing.allocator, -1);
    defer val.deinit(testing.allocator);
    try testing.expectEqualStrings("world", val.string);
}

test "luaToMsgpackValue sequential table becomes array" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    lua.createTable(3, 0);
    lua.pushInteger(10);
    lua.rawSetIndex(-2, 1);
    lua.pushInteger(20);
    lua.rawSetIndex(-2, 2);
    lua.pushInteger(30);
    lua.rawSetIndex(-2, 3);

    const val = try luaToMsgpackValue(lua, testing.allocator, -1);
    defer val.deinit(testing.allocator);

    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 3), val.array.len);
    try testing.expectEqual(@as(i64, 10), val.array[0].integer);
    try testing.expectEqual(@as(i64, 20), val.array[1].integer);
    try testing.expectEqual(@as(i64, 30), val.array[2].integer);
}

test "luaToMsgpackValue mixed table becomes map" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    lua.createTable(0, 1);
    _ = lua.pushString("value");
    lua.setField(-2, "key");

    const val = try luaToMsgpackValue(lua, testing.allocator, -1);
    defer val.deinit(testing.allocator);

    try testing.expect(val == .map);
    try testing.expectEqual(@as(usize, 1), val.map.len);
}

test "luaToMsgpackValue depth limit returns error" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    lua.createTable(0, 0);
    const result = luaToMsgpackValueDepth(
        lua,
        testing.allocator,
        -1,
        DEPTH_LIMIT,
    );
    try testing.expectError(error.DepthLimitExceeded, result);
}
