-- Tests for swap_pane and find_directional_leaf.
-- Mocks are constructed inline per the test_helpers phase-out policy:
-- new test files must not introduce new consumers of the shared helper.

---Create a minimal mock Pty with the methods the tiling module pokes at.
local function mock_pty(id)
    return {
        id = function()
            return id
        end,
        title = function()
            return "mock"
        end,
        cwd = function()
            return nil
        end,
        size = function()
            return { rows = 24, cols = 80, width_px = 0, height_px = 0 }
        end,
        send_key = function() end,
        send_mouse = function() end,
        send_paste = function() end,
        set_focus = function() end,
        close = function() end,
        copy_selection = function() end,
    }
end

local function mock_pane(id)
    return { type = "pane", id = id, pty = mock_pty(id) }
end

local function mock_split(id, direction, children)
    return { type = "split", split_id = id, direction = direction, children = children }
end

-- Install the prise mock module before loading tiling.
package.loaded["prise"] = {
    tiling = function() end,
    Terminal = function(opts)
        return { type = "terminal", pty = opts.pty }
    end,
    Text = function(_)
        return { type = "text" }
    end,
    Column = function(_)
        return { type = "column" }
    end,
    Row = function(_)
        return { type = "row" }
    end,
    Stack = function(_)
        return { type = "stack" }
    end,
    Positioned = function(_)
        return { type = "positioned" }
    end,
    TextInput = function(_)
        return { type = "text_input" }
    end,
    List = function(_)
        return { type = "list" }
    end,
    Box = function(_)
        return { type = "box" }
    end,
    Padding = function(_)
        return { type = "padding" }
    end,
    gwidth = function(s)
        return #s
    end,
    request_frame = function() end,
    save = function() end,
    exit = function() end,
    get_session_name = function()
        return "test"
    end,
    create_text_input = function()
        return {
            text = function()
                return ""
            end,
            clear = function() end,
            insert = function() end,
            handle_key = function() end,
            draw = function() end,
        }
    end,
    log = {
        info = function() end,
        warn = function() end,
        err = function() end,
    },
    list_sessions = function()
        return {}
    end,
    switch_session = function() end,
    attach = function() end,
}

local tiling = require("tiling")
local t = tiling._test

---Point the test state at a single-tab layout.
---@param root Pane|Split
---@param focused_id integer
local function setup_swap_test(root, focused_id)
    t.set_state({
        tabs = { { id = 1, root = root, last_focused_id = focused_id } },
        active_tab = 1,
        focused_id = focused_id,
    })
end

---Walk the active tab's tree and find the leaf currently at the given
---position in a flat pre-order traversal. Lets tests address "the first
---leaf", "the second leaf", etc. without worrying about mutable ids.
---@param index integer
---@return Pane?
local function leaf_at(index)
    local panes = t.collect_panes(t.get_state().tabs[1].root)
    return panes[index]
end

-- === swap_pane: adjacent horizontal split ===

-- [A | B], focus A, swap right → focus still on A's content, now on the right.
local row_ab = mock_split(1, "row", { mock_pane(1), mock_pane(2) })
setup_swap_test(row_ab, 1)
t.action_handlers.swap_pane_right()
assert(leaf_at(1).id == 2, "swap_pane right: left position now carries the other leaf's id")
assert(leaf_at(2).id == 1, "swap_pane right: right position now carries the focused leaf's id")
assert(t.get_state().focused_id == 1, "swap_pane right: focus id unchanged (follows content)")
assert(leaf_at(2).pty:id() == 1, "swap_pane right: pty moved with id")

-- Swap back (left) returns to original layout.
t.action_handlers.swap_pane_left()
assert(leaf_at(1).id == 1, "swap_pane left: returns to original position")
assert(leaf_at(2).id == 2, "swap_pane left: other leaf back at right")
assert(t.get_state().focused_id == 1, "swap_pane left: focus id still unchanged")

-- === swap_pane: adjacent vertical split ===

-- [A / B], focus B, swap up → focus stays on B's content, now on top.
local col_ab = mock_split(1, "col", { mock_pane(1), mock_pane(2) })
setup_swap_test(col_ab, 2)
t.action_handlers.swap_pane_up()
assert(leaf_at(1).id == 2, "swap_pane up: top position now holds B")
assert(leaf_at(2).id == 1, "swap_pane up: bottom position now holds A")
assert(t.get_state().focused_id == 2, "swap_pane up: focus id unchanged")

-- === swap_pane: nested splits — swap across parent boundary ===

-- [A | [B / C]], focus B, swap left → B and A trade positions.
-- The nested column containing C is replaced by B's pane node at the
-- top-level row.
local nested = mock_split(1, "row", {
    mock_pane(1),
    mock_split(2, "col", { mock_pane(2), mock_pane(3) }),
})
setup_swap_test(nested, 2)
t.action_handlers.swap_pane_left()
-- After swap: the top-level row's first child (left) should be B's leaf,
-- not A's. A now sits where B was inside the nested column.
local top_row = t.get_state().tabs[1].root
assert(top_row.type == "split", "swap_pane nested: tree structure preserved")
assert(top_row.children[1].type == "pane", "swap_pane nested: left is still a pane leaf")
assert(top_row.children[1].id == 2, "swap_pane nested: left now holds B")
local nested_col = top_row.children[2]
assert(nested_col.type == "split", "swap_pane nested: right still a column split")
assert(nested_col.children[1].id == 1, "swap_pane nested: A moved into B's old slot")
assert(nested_col.children[2].id == 3, "swap_pane nested: C unchanged")
assert(t.get_state().focused_id == 2, "swap_pane nested: focus id unchanged")

-- === swap_pane: no neighbor in direction → no-op ===

-- [A | B], focus B, swap right (no wrap) → nothing changes.
local row_noop = mock_split(1, "row", { mock_pane(1), mock_pane(2) })
setup_swap_test(row_noop, 2)
t.action_handlers.swap_pane_right()
assert(leaf_at(1).id == 1, "swap_pane right at edge: layout unchanged (1)")
assert(leaf_at(2).id == 2, "swap_pane right at edge: layout unchanged (2)")
assert(t.get_state().focused_id == 2, "swap_pane right at edge: focus unchanged")

-- === swap_pane: single pane → no-op ===

setup_swap_test(mock_pane(1), 1)
t.action_handlers.swap_pane_right()
assert(t.get_state().tabs[1].root.id == 1, "swap_pane single: root unchanged")
assert(t.get_state().focused_id == 1, "swap_pane single: focus unchanged")

-- === swap_pane: at edge in a wider layout → no-op ===

local row_abc = mock_split(1, "row", { mock_pane(1), mock_pane(2), mock_pane(3) })
setup_swap_test(row_abc, 3)
t.action_handlers.swap_pane_right()
assert(leaf_at(1).id == 1, "swap_pane right at edge: layout unchanged")
assert(leaf_at(3).id == 3, "swap_pane right at edge: focus pane stays")

-- === swap_pane: pty identity follows the id ===

-- After a swap, the leaf with id=N should have pty:id()==N, i.e. the
-- (id, pty) tuple moves as a unit.
local row_check = mock_split(1, "row", { mock_pane(1), mock_pane(2) })
setup_swap_test(row_check, 1)
t.action_handlers.swap_pane_right()
assert(leaf_at(1).id == 2 and leaf_at(1).pty:id() == 2, "swap_pane: id/pty tuple stays consistent (left)")
assert(leaf_at(2).id == 1 and leaf_at(2).pty:id() == 1, "swap_pane: id/pty tuple stays consistent (right)")

-- === swap_pane: axis mismatch → no-op ===

-- Swap in a direction whose split type doesn't appear in the layout
-- (up/down on a row-only layout) exercises the "no neighbor" branch of
-- find_directional_leaf.
local row_check2 = mock_split(1, "row", { mock_pane(10), mock_pane(11) })
setup_swap_test(row_check2, 10)
t.action_handlers.swap_pane_down()
assert(leaf_at(1).id == 10, "swap_pane down on row-only: layout unchanged")
assert(leaf_at(2).id == 11, "swap_pane down on row-only: other pane unchanged")

print("tiling_test_swap_pane: ok")
