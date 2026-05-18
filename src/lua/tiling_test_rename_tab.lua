local helpers = require("test_helpers")
local mock_pane = helpers.mock_pane
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

-- === find_tab_for_pane ===

-- Test: find_tab_for_pane finds floating pane
local floating_tab = mock_tab(mock_pane(1), mock_pane(9))
local original_tabs = state.tabs
state.tabs = { floating_tab }
local tab_idx, tab = t.find_tab_for_pane(9)
assert(tab_idx == 1, "find_tab_for_pane: floating pane index")
assert(tab == floating_tab, "find_tab_for_pane: floating pane tab")
state.tabs = original_tabs

-- === rename_tab ===

-- Test: rename_tab sets tab title
state.tabs = { mock_tab(mock_pane(1)) }
tiling.update({ type = "rename_tab", data = { pty_id = 1, title = "work" } })
assert(state.tabs[1].title == "work", "rename_tab: sets title")

-- Test: rename_tab clears title with empty string
state.tabs = { mock_tab(mock_pane(1)) }
state.tabs[1].title = "work"
tiling.update({ type = "rename_tab", data = { pty_id = 1, title = "" } })
assert(state.tabs[1].title == nil, "rename_tab: clears title with empty string")

-- Test: rename_tab on floating pane
state.tabs = { mock_tab(mock_pane(1), mock_pane(9)) }
tiling.update({ type = "rename_tab", data = { pty_id = 9, title = "floating work" } })
assert(state.tabs[1].title == "floating work", "rename_tab: sets title via floating pane")

-- Test: rename_tab with unknown pty_id does not crash
state.tabs = { mock_tab(mock_pane(1)) }
local tabs_before = state.tabs[1]
tiling.update({ type = "rename_tab", data = { pty_id = 999, title = "ghost" } })
assert(state.tabs[1] == tabs_before, "rename_tab: unknown pty_id leaves tabs unchanged")
assert(state.tabs[1].title == nil, "rename_tab: unknown pty_id does not set title")
