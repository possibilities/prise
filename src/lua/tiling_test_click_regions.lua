local helpers = require("test_helpers")
local mock_pane = helpers.mock_pane
helpers.setup_prise_mock()

local tiling = require("tiling")
local t = tiling._test

-- === custom tab bar click regions ===

tiling.setup({
    tab_bar = {
        render = function()
            return {
                { text = "pre>" },
                { text = "tab1", tab_index = 1 },
                { text = "*", tab_index = 1 },
                { text = " | " },
                { text = "tab2", tab_index = 2 },
                { text = "+", tab_index = 2 },
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
assert(#click_state.tab_regions == 4, "annotated tab bar: creates one region per annotated segment")
assert(
    click_state.tab_regions[1].start_x == 4 and click_state.tab_regions[1].end_x == 8,
    "annotated tab bar: prefix offsets first tab segment"
)
assert(click_state.tab_regions[1].tab_index == 1, "annotated tab bar: first segment maps to tab 1")
assert(
    click_state.tab_regions[2].start_x == 8 and click_state.tab_regions[2].end_x == 9,
    "annotated tab bar: second segment stays on tab 1"
)
assert(
    click_state.tab_regions[3].start_x == 12 and click_state.tab_regions[3].end_x == 16,
    "annotated tab bar: second tab starts after unannotated separator"
)
assert(click_state.tab_regions[4].tab_index == 2, "annotated tab bar: final segment maps to tab 2")
tiling.update({
    type = "mouse",
    data = {
        action = "press",
        button = "left",
        x = 12,
        y = 0,
    },
})
assert(t.get_state().active_tab == 2, "annotated tab bar: click uses annotated hit regions")
