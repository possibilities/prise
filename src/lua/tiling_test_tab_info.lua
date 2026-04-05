local helpers = require("test_helpers")
local mock_pane = helpers.mock_pane
local mock_split = helpers.mock_split
local mock_tab = helpers.mock_tab
helpers.setup_prise_mock()

local tiling = require("tiling")
local t = tiling._test

local state
for i = 1, 256 do
    local name, val = debug.getupvalue(tiling.update, i)
    if not name then
        break
    end
    if name == "state" then
        state = val
        break
    end
end
assert(state, "could not find state upvalue")

-- === collect_tab_panes ===

-- Test: collect_tab_panes includes floating pane
local split_node = mock_split(1, "row", { mock_pane(1), mock_pane(2) })
local floating_pane = mock_pane(9)
local tab_with_floating = mock_tab(split_node, floating_pane)
local panes = t.collect_tab_panes(tab_with_floating)
assert(#panes == 3, "collect_tab_panes: includes floating pane")
assert(panes[3].id == 9, "collect_tab_panes: floating pane last")

-- === get_active_tab_info ===

-- Test: get_active_tab_info with single pane tab
local p1 = mock_pane(1)
state.tabs = { mock_tab(p1) }
state.active_tab = 1
state.focused_id = 1
local info = tiling.get_active_tab_info()
assert(info ~= nil, "get_active_tab_info: single pane not nil")
assert(info.index == 1, "get_active_tab_info: index is 1")
assert(type(info.title) == "string", "get_active_tab_info: title is string")
assert(info.pane_count == 1, "get_active_tab_info: pane_count is 1")

-- Test: get_active_tab_info with no tabs
state.tabs = {}
state.active_tab = 1
info = tiling.get_active_tab_info()
assert(info == nil, "get_active_tab_info: no tabs returns nil")

-- Test: get_active_tab_info with 3-pane split
local three_split = mock_split(1, "col", {
    mock_pane(1),
    mock_split(2, "row", {
        mock_pane(2),
        mock_pane(3),
    }),
})
state.tabs = { mock_tab(three_split) }
state.active_tab = 1
state.focused_id = 1
info = tiling.get_active_tab_info()
assert(info ~= nil, "get_active_tab_info: 3-pane not nil")
assert(info.pane_count == 3, "get_active_tab_info: 3-pane count")

-- Test: get_active_tab_info with floating pane
local float_pane = mock_pane(9)
state.tabs = { mock_tab(mock_pane(1), float_pane) }
state.active_tab = 1
state.focused_id = 1
info = tiling.get_active_tab_info()
assert(info ~= nil, "get_active_tab_info: floating not nil")
assert(info.pane_count == 2, "get_active_tab_info: floating included in count")

-- === get_focused_pane_index ===

-- Test: get_focused_pane_index with focused on first pane
local split_two = mock_split(1, "row", { mock_pane(10), mock_pane(20) })
state.tabs = { mock_tab(split_two) }
state.active_tab = 1
state.focused_id = 10
local idx = tiling.get_focused_pane_index()
assert(idx == 1, "get_focused_pane_index: first pane returns 1")

-- Test: get_focused_pane_index with focused on second pane
state.focused_id = 20
idx = tiling.get_focused_pane_index()
assert(idx == 2, "get_focused_pane_index: second pane returns 2")

-- Test: get_focused_pane_index with no focused pane
state.focused_id = nil
idx = tiling.get_focused_pane_index()
assert(idx == nil, "get_focused_pane_index: nil focused returns nil")

-- Test: get_focused_pane_index with no tabs
state.tabs = {}
state.active_tab = 1
state.focused_id = 10
idx = tiling.get_focused_pane_index()
assert(idx == nil, "get_focused_pane_index: no tabs returns nil")

-- Test: get_focused_pane_index with pane not in active tab
state.tabs = { mock_tab(mock_pane(10)) }
state.active_tab = 1
state.focused_id = 99
idx = tiling.get_focused_pane_index()
assert(idx == nil, "get_focused_pane_index: pane not in tab returns nil")
