-- Tests for swap_tab_left_wrap and swap_tab_right_wrap.
local helpers = require("test_helpers")
local mock_pane = helpers.mock_pane
local mock_tab = helpers.mock_tab
helpers.setup_prise_mock()

local tiling = require("tiling")
local t = tiling._test

---Build a state populated with N tabs keyed by id 1..N, active at active_idx.
---@param n integer
---@param active_idx integer
local function setup_tabs(n, active_idx)
    local tabs = {}
    for i = 1, n do
        local tab = mock_tab(mock_pane(i))
        tab.id = i
        table.insert(tabs, tab)
    end
    t.set_state({ tabs = tabs, active_tab = active_idx, focused_id = active_idx })
end

---Return the id sequence of tabs in the current state.
---@return integer[]
local function tab_ids()
    local ids = {}
    for _, tab in ipairs(t.get_state().tabs) do
        table.insert(ids, tab.id)
    end
    return ids
end

local function assert_ids(expected, msg)
    local actual = tab_ids()
    assert(#actual == #expected, msg .. ": length mismatch (got " .. #actual .. ", want " .. #expected .. ")")
    for i, id in ipairs(expected) do
        assert(actual[i] == id, msg .. ": position " .. i .. " got " .. actual[i] .. ", want " .. id)
    end
end

-- === swap_tab_right_wrap: non-edge pairwise swap ===
-- [1,2,3] active=1, swap right wrap -> [2,1,3] active=2
setup_tabs(3, 1)
t.action_handlers.swap_tab_right_wrap()
assert_ids({ 2, 1, 3 }, "swap_tab_right_wrap: non-edge pairwise")
assert(t.get_state().active_tab == 2, "swap_tab_right_wrap: active follows content")

-- === swap_tab_right_wrap: wrap at right edge rotates ===
-- [1,2,3] active=3, swap right wrap -> [3,1,2] active=1
setup_tabs(3, 3)
t.action_handlers.swap_tab_right_wrap()
assert_ids({ 3, 1, 2 }, "swap_tab_right_wrap: wraps to front rotating others right")
assert(t.get_state().active_tab == 1, "swap_tab_right_wrap: active is now first")

-- === swap_tab_left_wrap: non-edge pairwise swap ===
-- [1,2,3] active=3, swap left wrap -> [1,3,2] active=2
setup_tabs(3, 3)
t.action_handlers.swap_tab_left_wrap()
assert_ids({ 1, 3, 2 }, "swap_tab_left_wrap: non-edge pairwise")
assert(t.get_state().active_tab == 2, "swap_tab_left_wrap: active follows content")

-- === swap_tab_left_wrap: wrap at left edge rotates ===
-- [1,2,3] active=1, swap left wrap -> [2,3,1] active=3
setup_tabs(3, 1)
t.action_handlers.swap_tab_left_wrap()
assert_ids({ 2, 3, 1 }, "swap_tab_left_wrap: wraps to back rotating others left")
assert(t.get_state().active_tab == 3, "swap_tab_left_wrap: active is now last")

-- === Round-trip: right_wrap then left_wrap returns to original ===
setup_tabs(3, 3)
t.action_handlers.swap_tab_right_wrap() -- [3,1,2] active=1
t.action_handlers.swap_tab_left_wrap() -- wrap back: [1,2,3] active=3
assert_ids({ 1, 2, 3 }, "round-trip: right_wrap + left_wrap restores layout")
assert(t.get_state().active_tab == 3, "round-trip: active back at last")

-- === Two-tab case: wrap-right from last goes to first ===
-- [1,2] active=2, swap right wrap -> [2,1] active=1
setup_tabs(2, 2)
t.action_handlers.swap_tab_right_wrap()
assert_ids({ 2, 1 }, "swap_tab_right_wrap: two-tab wrap")
assert(t.get_state().active_tab == 1, "swap_tab_right_wrap: two-tab active follows")

-- === Single tab: no-op, no crash ===
setup_tabs(1, 1)
t.action_handlers.swap_tab_right_wrap()
assert_ids({ 1 }, "swap_tab_right_wrap: single tab is no-op")
assert(t.get_state().active_tab == 1, "swap_tab_right_wrap: single tab active unchanged")

t.action_handlers.swap_tab_left_wrap()
assert_ids({ 1 }, "swap_tab_left_wrap: single tab is no-op")
assert(t.get_state().active_tab == 1, "swap_tab_left_wrap: single tab active unchanged")

-- === Non-active tabs preserved through wrap rotation ===
-- [1,2,3,4] active=4, swap right wrap -> [4,1,2,3] active=1
-- Middle tabs 2,3 keep relative order; tab 1 slides right by one.
setup_tabs(4, 4)
t.action_handlers.swap_tab_right_wrap()
assert_ids({ 4, 1, 2, 3 }, "swap_tab_right_wrap: non-active relative order preserved")
assert(t.get_state().active_tab == 1, "swap_tab_right_wrap: four-tab wrap active is first")

-- === Non-edge swap on 4 tabs leaves wrap path unused ===
-- [1,2,3,4] active=2, swap right wrap -> [1,3,2,4] active=3
setup_tabs(4, 2)
t.action_handlers.swap_tab_right_wrap()
assert_ids({ 1, 3, 2, 4 }, "swap_tab_right_wrap: middle swap is pairwise")
assert(t.get_state().active_tab == 3, "swap_tab_right_wrap: middle swap active follows")
