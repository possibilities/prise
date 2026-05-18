//! Lua unit tests
//!
//! Runs Lua test files through ziglua to verify Lua utility functions.

const std = @import("std");
const ziglua = @import("zlua");

fn runLuaTest(lua: *ziglua.Lua, file: [:0]const u8) !void {
    lua.doFile(file) catch {
        const err_msg = lua.toString(-1) catch "(no error message)";
        std.debug.print("\nLua error: {s}\n", .{err_msg});
        return error.LuaTestFailed;
    };
}

fn setupLua(allocator: std.mem.Allocator) !*ziglua.Lua {
    var lua = try ziglua.Lua.init(allocator);
    lua.openLibs();

    // Set up package.path to find our Lua modules
    _ = try lua.getGlobal("package");
    _ = lua.pushString("src/lua/?.lua");
    lua.setField(-2, "path");
    lua.pop(1);

    return lua;
}

test "lua utils" {
    var lua = try setupLua(std.testing.allocator);
    defer lua.deinit();
    try runLuaTest(lua, "src/lua/utils_test.lua");
}

test "lua prise" {
    var lua = try setupLua(std.testing.allocator);
    defer lua.deinit();
    try runLuaTest(lua, "src/lua/prise_test.lua");
}

test "lua tiling" {
    var lua = try setupLua(std.testing.allocator);
    defer lua.deinit();
    try runLuaTest(lua, "src/lua/tiling_test.lua");
}

test "lua tiling zoom state" {
    var lua = try setupLua(std.testing.allocator);
    defer lua.deinit();
    try runLuaTest(lua, "src/lua/tiling_test_zoom_state.lua");
}

test "lua tiling rename tab" {
    var lua = try setupLua(std.testing.allocator);
    defer lua.deinit();
    try runLuaTest(lua, "src/lua/tiling_test_rename_tab.lua");
}

test "lua tiling break pane" {
    var lua = try setupLua(std.testing.allocator);
    defer lua.deinit();
    try runLuaTest(lua, "src/lua/tiling_test_break_pane.lua");
}

test "lua tiling break pane to session" {
    var lua = try setupLua(std.testing.allocator);
    defer lua.deinit();
    try runLuaTest(lua, "src/lua/tiling_test_break_pane_to_session.lua");
}

test "lua tiling cross session break" {
    var lua = try setupLua(std.testing.allocator);
    defer lua.deinit();
    try runLuaTest(lua, "src/lua/tiling_test_cross_session_break.lua");
}

test "lua tiling move pane to session" {
    var lua = try setupLua(std.testing.allocator);
    defer lua.deinit();
    try runLuaTest(lua, "src/lua/tiling_test_move_pane_to_session.lua");
}

test "lua tiling keep_attached" {
    var lua = try setupLua(std.testing.allocator);
    defer lua.deinit();
    try runLuaTest(lua, "src/lua/tiling_test_keep_attached.lua");
}

test "lua tiling swap pane" {
    var lua = try setupLua(std.testing.allocator);
    defer lua.deinit();
    try runLuaTest(lua, "src/lua/tiling_test_swap_pane.lua");
}

test "lua tiling tab bar clean swap" {
    var lua = try setupLua(std.testing.allocator);
    defer lua.deinit();
    try runLuaTest(lua, "src/lua/tiling_test_tab_bar_clean_swap.lua");
}

test "lua tiling tab bar state" {
    var lua = try setupLua(std.testing.allocator);
    defer lua.deinit();
    try runLuaTest(lua, "src/lua/tiling_test_tab_bar_state.lua");
}

test "lua tiling deserialize" {
    var lua = try setupLua(std.testing.allocator);
    defer lua.deinit();
    try runLuaTest(lua, "src/lua/tiling_test_deserialize.lua");
}

test "lua tiling swap tab wrap" {
    var lua = try setupLua(std.testing.allocator);
    defer lua.deinit();
    try runLuaTest(lua, "src/lua/tiling_test_swap_tab_wrap.lua");
}

test "lua tiling click regions" {
    var lua = try setupLua(std.testing.allocator);
    defer lua.deinit();
    try runLuaTest(lua, "src/lua/tiling_test_click_regions.lua");
}

test "lua tiling input" {
    var lua = try setupLua(std.testing.allocator);
    defer lua.deinit();
    try runLuaTest(lua, "src/lua/tiling_test_input.lua");
}

test "lua tiling spawn" {
    var lua = try setupLua(std.testing.allocator);
    defer lua.deinit();
    try runLuaTest(lua, "src/lua/tiling_test_spawn.lua");
}

test "lua tiling theme" {
    var lua = try setupLua(std.testing.allocator);
    defer lua.deinit();
    try runLuaTest(lua, "src/lua/tiling_test_theme.lua");
}

test "lua tiling keep attached" {
    var lua = try setupLua(std.testing.allocator);
    defer lua.deinit();
    try runLuaTest(lua, "src/lua/tiling_test_keep_attached.lua");
}

test "lua tiling tab info" {
    var lua = try setupLua(std.testing.allocator);
    defer lua.deinit();
    try runLuaTest(lua, "src/lua/tiling_test_tab_info.lua");
}
