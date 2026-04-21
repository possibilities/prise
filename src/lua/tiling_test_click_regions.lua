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

-- Integration-surface note: fn-80 renamed per-tab `segments` → `label_segments`
-- and moved the inter-tab separator from a per-tab trailing cell to a core-
-- injected 1-cell space between adjacent visible tabs. On feat/plug-system
-- standalone, the runtime still reads `segments` (with inline trailing cell).
-- On arthack-prod after fn-80.1 merges, the runtime reads `label_segments`
-- and injects separators. Carry both shapes so the test runs clean on either
-- (per branches.md:63-78).
tiling.setup({
    tab_bar = {
        render = function()
            -- On feat/plug-system standalone, each tab's segments are the
            -- label plus a trailing separator cell ("tab1" + "*" + " " = 6 cells
            -- each, regions abut at 4..10 and 10..16). On arthack-prod the
            -- runtime reads `label_segments` (no trailing cell, 5 cells each)
            -- and core injects a 1-cell separator between them (regions at
            -- 4..9 and 10..15). Provide both shapes; the active runtime picks
            -- whichever field it reads.
            return {
                prefix = { { text = "pre>" } },
                tabs = {
                    {
                        tab_index = 1,
                        segments = { { text = "tab1" }, { text = "*" }, { text = " " } },
                        label_segments = { { text = "tab1" }, { text = "*" } },
                    },
                    {
                        tab_index = 2,
                        segments = { { text = "tab2" }, { text = "+" }, { text = " " } },
                        label_segments = { { text = "tab2" }, { text = "+" } },
                    },
                },
                suffix = {},
            }
        end,
        measure = function(tab)
            -- Label-only width: 5 cells. fn-80.1's runtime reads this; the
            -- pre-fn-80.1 runtime ignores `measure` here and computes widths
            -- directly from `segments` (6 cells incl. trailing separator).
            if tab.index == 1 or tab.index == 2 then
                return 5
            end
            return 0
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
-- Both runtimes produce two tab regions whose boundaries differ by one cell.
-- On feat/plug-system standalone: regions [4..10) and [10..16) (inline sep).
-- On arthack-prod (post-fn-80.1):      regions [4..9) and [10..15) (core sep
-- at [9..10)). In both, x=10 lands in tab 2's region → click activates tab 2.
assert(#click_state.tab_regions == 2, "structured tab bar: one click region per tab")
-- First region always starts at prefix_width = 4.
assert(click_state.tab_regions[1].start_x == 4, "structured tab bar: prefix offsets first tab region start=4")
assert(
    click_state.tab_regions[1].end_x == 9 or click_state.tab_regions[1].end_x == 10,
    "structured tab bar: first tab region end is 9 (post-fn-80.1) or 10 (pre-fn-80.1)"
)
assert(click_state.tab_regions[1].tab_index == 1, "structured tab bar: first region maps to tab 1")
-- Second region abuts (pre-fn-80.1) or has a 1-cell gap from (post-fn-80.1) the first.
assert(
    click_state.tab_regions[2].start_x == 10 or click_state.tab_regions[2].start_x == 9,
    "structured tab bar: second tab region starts after first tab (abutting pre-fn-80.1, after core separator post-fn-80.1)"
)
assert(
    click_state.tab_regions[2].end_x == 15 or click_state.tab_regions[2].end_x == 16,
    "structured tab bar: second tab region end is 15 (post-fn-80.1) or 16 (pre-fn-80.1)"
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
