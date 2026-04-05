//! Helpers for editing saved session JSON.

const std = @import("std");

/// Update the saved tab title for the tab containing `pty_id`.
/// Returns `null` when the PTY does not exist in the session JSON.
pub fn updateTabTitle(allocator: std.mem.Allocator, json: []const u8, pty_id: u32, title: ?[]const u8) !?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, json, .{});
    if (parsed.value != .object) return null;

    const tabs = parsed.value.object.get("tabs") orelse return null;
    if (tabs != .array) return null;

    for (tabs.array.items) |*tab| {
        if (tabContainsPty(tab, pty_id)) {
            try setTabTitle(arena, tab, title);
            return try stringifyValue(allocator, parsed.value);
        }
    }

    return null;
}

/// Update the saved session file in place when the PTY exists in the file.
pub fn updateTabTitleFile(allocator: std.mem.Allocator, session_path: []const u8, pty_id: u32, title: ?[]const u8) !bool {
    const file = std.fs.openFileAbsolute(session_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close();

    const json = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(json);

    const updated = try updateTabTitle(allocator, json, pty_id, title) orelse return false;
    defer allocator.free(updated);

    const output = try std.fs.createFileAbsolute(session_path, .{});
    defer output.close();
    try output.writeAll(updated);
    return true;
}

fn stringifyValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try list.writer(allocator).print("{f}", .{std.json.fmt(value, .{})});
    return list.toOwnedSlice(allocator);
}

fn setTabTitle(allocator: std.mem.Allocator, tab: *std.json.Value, title: ?[]const u8) !void {
    std.debug.assert(tab.* == .object);

    var entry_it = tab.object.iterator();
    while (entry_it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "title")) {
            entry.value_ptr.* = try titleValue(allocator, title);
            return;
        }
    }

    try tab.object.put(try allocator.dupe(u8, "title"), try titleValue(allocator, title));
}

fn titleValue(allocator: std.mem.Allocator, title: ?[]const u8) !std.json.Value {
    if (title) |tab_title| {
        return .{ .string = try allocator.dupe(u8, tab_title) };
    }
    return .null;
}

fn tabContainsPty(tab: *const std.json.Value, pty_id: u32) bool {
    if (tab.* != .object) return false;
    if (tab.object.get("root")) |root| {
        if (nodeContainsPty(&root, pty_id)) return true;
    }
    if (tab.object.get("floating")) |floating| {
        if (floatingContainsPty(&floating, pty_id)) return true;
    }
    return false;
}

fn floatingContainsPty(floating: *const std.json.Value, pty_id: u32) bool {
    if (floating.* != .object) return false;
    const pane = floating.object.get("pane") orelse return false;
    return nodeContainsPty(&pane, pty_id);
}

fn nodeContainsPty(node: *const std.json.Value, pty_id: u32) bool {
    if (node.* != .object) return false;

    const node_type = node.object.get("type") orelse return false;
    if (node_type != .string) return false;

    if (std.mem.eql(u8, node_type.string, "pane")) {
        const pane_pty_id = node.object.get("pty_id") orelse return false;
        return switch (pane_pty_id) {
            .integer => pane_pty_id.integer == pty_id,
            else => false,
        };
    }

    if (!std.mem.eql(u8, node_type.string, "split")) return false;
    const children = node.object.get("children") orelse return false;
    if (children != .array) return false;

    for (children.array.items) |child| {
        if (nodeContainsPty(&child, pty_id)) return true;
    }
    return false;
}

test "updateTabTitle updates pane title in root layout" {
    const json =
        \\{"tabs":[{"id":1,"root":{"type":"pane","id":10,"pty_id":42}}],"active_tab":1}
    ;

    const updated = (try updateTabTitle(std.testing.allocator, json, 42, "renamed")).?;
    defer std.testing.allocator.free(updated);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, updated, .{});
    defer parsed.deinit();

    const tabs = parsed.value.object.get("tabs").?.array.items;
    try std.testing.expect(tabContainsPty(&tabs[0], 42));
    try std.testing.expectEqualStrings("renamed", tabs[0].object.get("title").?.string);
}

test "updateTabTitle updates pane title in floating layout" {
    const json =
        \\{"tabs":[{"id":1,"root":{"type":"pane","id":10,"pty_id":42},"floating":{"pane":{"type":"pane","id":11,"pty_id":99},"visible":true}}],"active_tab":1}
    ;

    const updated = (try updateTabTitle(std.testing.allocator, json, 99, "floating")).?;
    defer std.testing.allocator.free(updated);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, updated, .{});
    defer parsed.deinit();

    const tabs = parsed.value.object.get("tabs").?.array.items;
    try std.testing.expect(tabContainsPty(&tabs[0], 99));
    try std.testing.expectEqualStrings("floating", tabs[0].object.get("title").?.string);
}

test "updateTabTitle clears saved title with null" {
    const json =
        \\{"tabs":[{"id":1,"title":"old","root":{"type":"pane","id":10,"pty_id":42}}],"active_tab":1}
    ;

    const updated = (try updateTabTitle(std.testing.allocator, json, 42, null)).?;
    defer std.testing.allocator.free(updated);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, updated, .{});
    defer parsed.deinit();

    const tabs = parsed.value.object.get("tabs").?.array.items;
    try std.testing.expectEqual(std.json.Value.null, tabs[0].object.get("title").?);
}

test "updateTabTitle returns null when pty is absent" {
    const json =
        \\{"tabs":[{"id":1,"root":{"type":"pane","id":10,"pty_id":42}}],"active_tab":1}
    ;

    const updated = try updateTabTitle(std.testing.allocator, json, 100, "missing");
    try std.testing.expect(updated == null);
}
