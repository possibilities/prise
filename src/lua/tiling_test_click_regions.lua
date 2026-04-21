local helpers = require("test_helpers")
local mock_pane = helpers.mock_pane
helpers.setup_prise_mock()

-- Install a minimal prise.cell_substring pass-through so build_tab_bar_custom's
-- boundary clipping can run. The default mock in test_helpers doesn't ship this
-- field.
package.loaded["prise"].cell_substring = function(s, start_cell, end_cell)
    return s:sub(start_cell + 1, end_cell)
end

local tiling = require("tiling")
local t = tiling._test

-- === custom tab bar click regions ===
-- The structured layout contract routes click regions through derive_click_regions
-- (per-tab, never per-segment). This test pins the end-to-end path: custom render
-- returns { prefix, tabs, suffix }; core composes the strip and emits one click
-- region per tab, x-offset by prefix width; a mouse click inside a tab's region
-- activates that tab.

tiling.setup({
    tab_bar = {
        render = function()
            return {
                prefix = { { text = "pre>" } },
                tabs = {
                    { tab_index = 1, segments = { { text = "tab1" }, { text = "*" } } },
                    { tab_index = 2, segments = { { text = "tab2" }, { text = "+" } } },
                },
                suffix = {},
            }
        end,
    },
})
t.set_state({
    tabs = {
        { id = 1, root = mock_pane(1), last_focused_id = 1 },
        { id = 2, root = mock_pane(2), last_focused_id = 2 },
    },
    active_tab = 1,
    focused_id = 1,
})
t.build_tab_bar_custom()
local click_state = t.get_state()
-- prefix "pre>" is 4 cells; tab1 segments sum to 5 cells ("tab1"+"*"); tab2 to 5.
-- Two tabs → two click regions, offset by prefix width = 4.
assert(#click_state.tab_regions == 2, "structured tab bar: one click region per tab")
assert(
    click_state.tab_regions[1].start_x == 4 and click_state.tab_regions[1].end_x == 9,
    "structured tab bar: prefix offsets first tab region (4..9)"
)
assert(click_state.tab_regions[1].tab_index == 1, "structured tab bar: first region maps to tab 1")
assert(
    click_state.tab_regions[2].start_x == 9 and click_state.tab_regions[2].end_x == 14,
    "structured tab bar: second tab region abuts first (9..14)"
)
assert(click_state.tab_regions[2].tab_index == 2, "structured tab bar: second region maps to tab 2")
tiling.update({
    type = "mouse",
    data = {
        action = "press",
        button = "left",
        x = 10,
        y = 0,
    },
})
assert(t.get_state().active_tab == 2, "structured tab bar: click inside tab 2's region activates it")
