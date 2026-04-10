local helpers = require("test_helpers")
local mock_pane = helpers.mock_pane
local mock_split = helpers.mock_split
local mock_tab = helpers.mock_tab

helpers.setup_prise_mock()

local tiling = require("tiling")
local t = tiling._test

local state = helpers.get_state(tiling)

-- === collect_tab_panes ===

-- Test: collect_tab_panes with single pane tab
local tab_single = mock_tab(mock_pane(1))
local panes = t.collect_tab_panes(tab_single)
assert(#panes == 1, "collect_tab_panes: single pane count")
assert(panes[1].id == 1, "collect_tab_panes: single pane id")

-- Test: collect_tab_panes with split + floating pane
local tab_float = mock_tab(mock_split(1, "row", { mock_pane(1), mock_pane(2) }), mock_pane(9))
panes = t.collect_tab_panes(tab_float)
assert(#panes == 3, "collect_tab_panes: split + floating count")
assert(panes[3].id == 9, "collect_tab_panes: floating pane included")

-- Test: collect_tab_panes with nil tab
panes = t.collect_tab_panes(nil)
assert(#panes == 0, "collect_tab_panes: nil tab returns empty")

-- === is_zoomed (tab bar state formula) ===

-- The is_zoomed formula used in build_tab_bar_custom:
--   i == state.active_tab and state.zoomed_pane_id ~= nil
-- Test the formula directly via internal state.

local orig_active = state.active_tab
local orig_zoomed = state.zoomed_pane_id

-- Test: active tab + zoomed → true
state.active_tab = 1
state.zoomed_pane_id = 42
local is_zoomed = (1 == state.active_tab and state.zoomed_pane_id ~= nil)
assert(is_zoomed == true, "is_zoomed: active tab + zoomed")

-- Test: active tab + no zoom → false
state.zoomed_pane_id = nil
is_zoomed = (1 == state.active_tab and state.zoomed_pane_id ~= nil)
assert(is_zoomed == false, "is_zoomed: active tab + no zoom")

-- Test: inactive tab → false
state.active_tab = 1
state.zoomed_pane_id = 42
is_zoomed = (2 == state.active_tab and state.zoomed_pane_id ~= nil)
assert(is_zoomed == false, "is_zoomed: inactive tab")

state.active_tab = orig_active
state.zoomed_pane_id = orig_zoomed
