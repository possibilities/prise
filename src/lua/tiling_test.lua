local helpers = require("test_helpers")
local mock_pane = helpers.mock_pane
local mock_split = helpers.mock_split
local mock_tab = helpers.mock_tab
local mock_pty = helpers.mock_pty
helpers.setup_prise_mock()

local tiling = require("tiling")
local t = tiling._test

-- === is_pane / is_split ===

-- Test: is_pane with pane node
assert(t.is_pane({ type = "pane", id = 1 }) == true, "is_pane: pane node")

-- Test: is_pane with split node
assert(t.is_pane({ type = "split" }) == false, "is_pane: split node")

-- Test: is_pane with nil
assert(not t.is_pane(nil), "is_pane: nil")

-- Test: is_split with split node
assert(t.is_split({ type = "split", children = {} }) == true, "is_split: split node")

-- Test: is_split with pane node
assert(t.is_split({ type = "pane" }) == false, "is_split: pane node")

-- Test: is_split with nil
assert(not t.is_split(nil), "is_split: nil")

-- === collect_panes ===

-- Test: collect_panes with nil
local panes = t.collect_panes(nil)
assert(#panes == 0, "collect_panes: nil returns empty")

-- Test: collect_panes with single pane
local single_pane = mock_pane(1)
panes = t.collect_panes(single_pane)
assert(#panes == 1, "collect_panes: single pane count")
assert(panes[1].id == 1, "collect_panes: single pane id")

-- Test: collect_panes with split containing panes
local split_node = mock_split(1, "row", {
    mock_pane(1),
    mock_pane(2),
})
panes = t.collect_panes(split_node)
assert(#panes == 2, "collect_panes: split with 2 panes")
assert(panes[1].id == 1, "collect_panes: first pane")
assert(panes[2].id == 2, "collect_panes: second pane")

-- Test: collect_panes with nested splits
local nested = mock_split(1, "col", {
    mock_pane(1),
    mock_split(2, "row", {
        mock_pane(2),
        mock_pane(3),
    }),
})
panes = t.collect_panes(nested)
assert(#panes == 3, "collect_panes: nested splits")
assert(panes[1].id == 1, "collect_panes: nested first")
assert(panes[2].id == 2, "collect_panes: nested second")
assert(panes[3].id == 3, "collect_panes: nested third")

-- === find_node_path ===

-- Test: find_node_path with nil
local path = t.find_node_path(nil, 1)
assert(path == nil, "find_node_path: nil returns nil")

-- Test: find_node_path with single pane (found)
local pane1 = mock_pane(1)
path = t.find_node_path(pane1, 1)
assert(path ~= nil, "find_node_path: single pane found")
assert(#path == 1, "find_node_path: path length 1")
assert(path[1].id == 1, "find_node_path: path contains pane")

-- Test: find_node_path with single pane (not found)
path = t.find_node_path(pane1, 99)
assert(path == nil, "find_node_path: single pane not found")

-- Test: find_node_path in split
local split_for_path = mock_split(1, "row", {
    mock_pane(1),
    mock_pane(2),
})
path = t.find_node_path(split_for_path, 2)
assert(path ~= nil, "find_node_path: found in split")
assert(#path == 2, "find_node_path: path through split")
assert(path[1].type == "split", "find_node_path: first is split")
assert(path[2].id == 2, "find_node_path: second is target pane")

-- Test: find_node_path in nested splits
local nested_for_path = mock_split(1, "col", {
    mock_pane(1),
    mock_split(2, "row", {
        mock_pane(2),
        mock_pane(3),
    }),
})
path = t.find_node_path(nested_for_path, 3)
assert(path ~= nil, "find_node_path: found in nested")
assert(#path == 3, "find_node_path: nested path length")
assert(path[1].type == "split", "find_node_path: nested first is split")
assert(path[2].type == "split", "find_node_path: nested second is split")
assert(path[3].id == 3, "find_node_path: nested third is target")

-- Test: find_node_path not found in nested
path = t.find_node_path(nested_for_path, 99)
assert(path == nil, "find_node_path: not found in nested")

-- === get_first_leaf ===

-- Test: get_first_leaf with nil
assert(t.get_first_leaf(nil) == nil, "get_first_leaf: nil")

-- Test: get_first_leaf with pane
local leaf_pane = mock_pane(5)
local leaf = t.get_first_leaf(leaf_pane)
assert(leaf ~= nil, "get_first_leaf: pane not nil")
assert(leaf.id == 5, "get_first_leaf: pane returns self")

-- Test: get_first_leaf with split
local split_for_leaf = mock_split(1, "row", {
    mock_pane(10),
    mock_pane(20),
})
leaf = t.get_first_leaf(split_for_leaf)
assert(leaf ~= nil, "get_first_leaf: split not nil")
assert(leaf.id == 10, "get_first_leaf: returns first child")

-- Test: get_first_leaf with nested splits
local nested_for_leaf = mock_split(1, "col", {
    mock_split(2, "row", {
        mock_pane(100),
        mock_pane(200),
    }),
    mock_pane(300),
})
leaf = t.get_first_leaf(nested_for_leaf)
assert(leaf ~= nil, "get_first_leaf: nested not nil")
assert(leaf.id == 100, "get_first_leaf: returns deepest first")

-- === get_last_leaf ===

-- Test: get_last_leaf with nil
assert(t.get_last_leaf(nil) == nil, "get_last_leaf: nil")

-- Test: get_last_leaf with pane
leaf = t.get_last_leaf(leaf_pane)
assert(leaf ~= nil, "get_last_leaf: pane not nil")
assert(leaf.id == 5, "get_last_leaf: pane returns self")

-- Test: get_last_leaf with split
leaf = t.get_last_leaf(split_for_leaf)
assert(leaf ~= nil, "get_last_leaf: split not nil")
assert(leaf.id == 20, "get_last_leaf: returns last child")

-- Test: get_last_leaf with nested splits
leaf = t.get_last_leaf(nested_for_leaf)
assert(leaf ~= nil, "get_last_leaf: nested not nil")
assert(leaf.id == 300, "get_last_leaf: returns deepest last")

-- Test: get_last_leaf with right-heavy nesting
local right_nested = mock_split(1, "col", {
    mock_pane(1),
    mock_split(2, "row", {
        mock_pane(2),
        mock_pane(3),
    }),
})
leaf = t.get_last_leaf(right_nested)
assert(leaf ~= nil, "get_last_leaf: right-heavy nested should return leaf")
assert(leaf.id == 3, "get_last_leaf: right-heavy nested")

-- === format_palette_item ===

-- Test: format_palette_item without shortcut
local item = t.format_palette_item("Close Pane", nil, 50)
assert(item == "Close Pane", "format_palette_item: no shortcut")

-- Test: format_palette_item with shortcut (using ASCII for predictable byte length)
item = t.format_palette_item("Close", "C-w", 20)
-- "Close" (5) + padding + "C-w" (3) = 20, padding = 12
assert(item:sub(1, 5) == "Close", "format_palette_item: name preserved")
assert(item:sub(-3) == "C-w", "format_palette_item: shortcut at end")
assert(#item == 20, "format_palette_item: correct width")

-- Test: format_palette_item with minimum padding
item = t.format_palette_item("Very Long Command Name", "C-x", 10)
-- Width is too small, should use minimum padding of 2
assert(item == "Very Long Command Name  C-x", "format_palette_item: minimum padding")

-- === pty_exited on solo main-tree pane with floating: floating closed on tab drop ===

do
    local float_pty = helpers.mock_pty(55) ---@type any
    float_pty._closed = false
    float_pty.close = function()
        float_pty._closed = true
    end
    local float_pane = { type = "pane", id = 55, pty = float_pty }
    local tab1 = {
        id = 1,
        root = mock_pane(10),
        last_focused_id = 10,
    }
    tab1.floating = { pane = float_pane, visible = true }
    t.set_state({
        tabs = {
            tab1,
            { id = 2, root = mock_pane(99), last_focused_id = 99 },
        },
        active_tab = 2,
        focused_id = 99,
        next_tab_id = 3,
    })
    tiling.update({ type = "pty_exited", data = { id = 10 } })
    local st = t.get_state()
    assert(#st.tabs == 1, "pty_exited float-orphan: source tab dropped")
    assert(st.tabs[1].root.id == 99, "pty_exited float-orphan: surviving tab is sibling")
    assert(float_pty._closed, "pty_exited float-orphan: floating pane pty closed")
end

-- === pty_exited on solo main-tree pane with overlay: overlay closed on tab drop ===

do
    local overlay_pty = helpers.mock_pty(66) ---@type any
    overlay_pty._closed = false
    overlay_pty.close = function()
        overlay_pty._closed = true
    end
    local overlay_pane = { type = "pane", id = 66, pty = overlay_pty }
    local tab1 = {
        id = 1,
        root = mock_pane(20),
        last_focused_id = 20,
    }
    tab1.overlays = { tools = { pane = overlay_pane, visible = true } }
    t.set_state({
        tabs = {
            tab1,
            { id = 2, root = mock_pane(99), last_focused_id = 99 },
        },
        active_tab = 2,
        focused_id = 99,
        next_tab_id = 3,
    })
    tiling.update({ type = "pty_exited", data = { id = 20 } })
    local st = t.get_state()
    assert(#st.tabs == 1, "pty_exited overlay-orphan: source tab dropped")
    assert(st.tabs[1].root.id == 99, "pty_exited overlay-orphan: surviving tab is sibling")
    assert(overlay_pty._closed, "pty_exited overlay-orphan: overlay pane pty closed")
end
-- === spawn placement ===

-- Get state upvalue from tiling.update
local state_upvalue
for i = 1, 100 do
    local name, value = debug.getupvalue(tiling.update, i)
    if name == "state" then
        state_upvalue = value
        break
    end
end
assert(state_upvalue ~= nil, "spawn placement: state upvalue found")

-- Test: pty_spawned with title queues pending rename (and creates new tab since tab is nil)
-- Integration-surface: plug-system branch moves new_tab from state.pending_new_tab to
-- state.pending_spawns[id].new_tab. Accept either model so the test passes both on
-- feat/spawn-pty alone and on arthack-prod after plug-system lands.
state_upvalue.pending_title_renames = {}
state_upvalue.pending_new_tab = false
state_upvalue.pending_spawns = state_upvalue.pending_spawns or {}
tiling.update({ type = "pty_spawned", data = { id = 5, title = "editor" } })
assert(state_upvalue.pending_title_renames[5] == "editor", "pty_spawned: title queues pending rename")
assert(
    state_upvalue.pending_new_tab == true
        or (state_upvalue.pending_spawns[5] and state_upvalue.pending_spawns[5].new_tab == true),
    "pty_spawned: nil tab creates new tab"
)

-- Test: pty_spawned with tab=<new> sets pending_new_tab
state_upvalue.pending_new_tab = false
state_upvalue.pending_spawns = state_upvalue.pending_spawns or {}
tiling.update({ type = "pty_spawned", data = { id = 6, tab = "<new>" } })
assert(
    state_upvalue.pending_new_tab == true
        or (state_upvalue.pending_spawns[6] and state_upvalue.pending_spawns[6].new_tab == true),
    "pty_spawned: tab=<new> sets pending_new_tab"
)

-- Test: pty_spawned without placement fields is no-op
state_upvalue.pending_new_tab = false
state_upvalue.pending_title_renames = {}
state_upvalue.pending_spawns = state_upvalue.pending_spawns or {}
tiling.update({ type = "pty_spawned", data = { id = 7 } })
assert(
    state_upvalue.pending_new_tab == false
        and (state_upvalue.pending_spawns[7] == nil or state_upvalue.pending_spawns[7].new_tab ~= true),
    "pty_spawned: no placement fields, pending_new_tab unchanged"
)
assert(state_upvalue.pending_title_renames[7] == nil, "pty_spawned: no placement fields, no pending rename")

-- === find_tab_by_title ===

-- Test: find_tab_by_title returns correct index and tab when found
state_upvalue.tabs = {
    { id = 1, root = mock_pane(1), title = "alpha" },
    { id = 2, root = mock_pane(2), title = "beta" },
    { id = 3, root = mock_pane(3), title = "gamma" },
}
local idx, tab = t.find_tab_by_title("beta")
assert(idx == 2, "find_tab_by_title: correct index")
assert(tab ~= nil and tab.title == "beta", "find_tab_by_title: correct tab")

-- Test: find_tab_by_title returns nil when not found
idx = t.find_tab_by_title("nonexistent")
assert(idx == nil, "find_tab_by_title: nil when not found")

-- === pty_spawned with named tab ===

-- Test: pty_spawned with known tab name activates that tab (no new tab)
state_upvalue.tabs = {
    { id = 1, root = mock_pane(1), title = "code", last_focused_id = 1 },
    { id = 2, root = mock_pane(2), title = "logs", last_focused_id = 2 },
}
state_upvalue.active_tab = 1
state_upvalue.pending_new_tab = false
state_upvalue.pending_title_renames = {}
state_upvalue.pending_spawns = state_upvalue.pending_spawns or {}
tiling.update({ type = "pty_spawned", data = { id = 20, tab = "logs" } })
assert(state_upvalue.active_tab == 2, "pty_spawned: known tab name activates tab")
assert(
    state_upvalue.pending_new_tab == false
        and (state_upvalue.pending_spawns[20] == nil or state_upvalue.pending_spawns[20].new_tab ~= true),
    "pty_spawned: known tab name does not create new tab"
)

-- Test: pty_spawned with unknown tab name creates new tab
state_upvalue.tabs = {
    { id = 1, root = mock_pane(1), title = "code", last_focused_id = 1 },
}
state_upvalue.active_tab = 1
state_upvalue.pending_new_tab = false
state_upvalue.pending_spawns = state_upvalue.pending_spawns or {}
tiling.update({ type = "pty_spawned", data = { id = 21, tab = "unknown" } })
assert(
    state_upvalue.pending_new_tab == true
        or (state_upvalue.pending_spawns[21] and state_upvalue.pending_spawns[21].new_tab == true),
    "pty_spawned: unknown tab name creates new tab"
)

-- === pty_spawned with missing session ===

-- Test: pty_spawned with session that doesn't exist calls prise.create_session
-- and bails early. Earlier behaviour rewrote the current session in place
-- (save + rename_session + clear tabs); the rewritten handler hands off to
-- prise.create_session and returns without touching state. Assert the new
-- contract.
local mock_prise = package.loaded["prise"]
local created_with = nil
---@diagnostic disable: duplicate-set-field
mock_prise.switch_session = function()
    return false
end
mock_prise.create_session = function(name)
    created_with = name
end
mock_prise.get_session_name = function()
    return "default"
end
---@diagnostic enable: duplicate-set-field

state_upvalue.tabs = { { id = 1, root = mock_pane(1), title = "old", last_focused_id = 1 } }
state_upvalue.active_tab = 1
state_upvalue.pending_new_tab = false
state_upvalue.pending_title_renames = {}
created_with = nil

tiling.update({ type = "pty_spawned", data = { id = 30, session = "newsession", tab = "<new>" } })
assert(
    created_with == "newsession",
    "pty_spawned: missing session calls prise.create_session with target name, got " .. tostring(created_with)
)

-- Restore mock defaults
---@diagnostic disable: duplicate-set-field
mock_prise.switch_session = function()
    return true
end
mock_prise.create_session = function() end
mock_prise.get_session_name = function()
    return "test"
end
---@diagnostic enable: duplicate-set-field

-- Test: pending title applied on pty_attach
state_upvalue.tabs = { mock_tab(mock_pane(1)) }
state_upvalue.active_tab = 1
state_upvalue.focused_id = 1
state_upvalue.pending_title_renames = { [10] = "my-title" }
state_upvalue.pending_new_tab = false
state_upvalue.pending_split = nil
state_upvalue.pending_layout = nil
state_upvalue.floating = { pending = false, visible = false, width = 100, height = 30 }
tiling.update({ type = "pty_attach", data = { pty = mock_pty(10) } })
assert(state_upvalue.tabs[1].title == "my-title", "pty_attach: pending title applied to tab")
assert(state_upvalue.pending_title_renames[10] == nil, "pty_attach: pending rename cleared")
