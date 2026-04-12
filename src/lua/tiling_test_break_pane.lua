-- Tests for M.list_tab_pty_ids and the break_pane event handler.
-- Mocks are constructed inline per the 2026-04-11 test_helpers phase-out
-- policy (see ~/docs/prise-scratchpad.md): touching a branch that uses
-- test_helpers is an opportunity to inline, and new test files must never
-- introduce new consumers of the shared helper module.

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
    attach = function() end,
    switch_session = function()
        return true
    end,
    rename_session = function() end,
    create_session = function() end,
    create_text_input = function()
        return {
            text = function()
                return ""
            end,
            clear = function() end,
            insert = function() end,
        }
    end,
    log = { debug = function() end, info = function() end },
    set_timeout = function(_, _)
        return { cancel = function() end }
    end,
    get_git_branch = function()
        return nil
    end,
    get_time = function()
        return "12:00"
    end,
    list_sessions = function()
        return {}
    end,
}

local tiling = require("tiling")
local t = tiling._test

-- Helper: shallow-scan an array for a value.
local function contains(arr, v)
    for _, x in ipairs(arr) do
        if x == v then
            return true
        end
    end
    return false
end

-- === list_tab_pty_ids: full id list for multi-pane tab ===

t.set_state({
    tabs = {
        {
            id = 1,
            root = mock_split(10, "row", {
                mock_pane(1),
                mock_pane(2),
                mock_pane(3),
            }),
            last_focused_id = 1,
        },
    },
    active_tab = 1,
    focused_id = 1,
})
local ids = tiling.list_tab_pty_ids(2)
assert(ids ~= nil, "list: multi-pane returns non-nil")
assert(#ids == 3, "list: multi-pane returns 3 ids, got " .. tostring(#ids))
assert(contains(ids, 1) and contains(ids, 2) and contains(ids, 3), "list: ids cover all panes")
-- Traversal order: collect_panes walks children left-to-right, so for a
-- flat split this matches insertion order.
assert(ids[1] == 1 and ids[2] == 2 and ids[3] == 3, "list: order matches traversal")

-- === list_tab_pty_ids: single-element list for solo pane ===

t.set_state({
    tabs = {
        { id = 1, root = mock_pane(42), last_focused_id = 42 },
    },
    active_tab = 1,
    focused_id = 42,
})
ids = tiling.list_tab_pty_ids(42)
assert(ids ~= nil and #ids == 1 and ids[1] == 42, "list: solo pane returns {self}")

-- === list_tab_pty_ids: unknown pty_id returns nil ===

t.set_state({
    tabs = {
        { id = 1, root = mock_pane(1), last_focused_id = 1 },
    },
    active_tab = 1,
    focused_id = 1,
})
assert(tiling.list_tab_pty_ids(999) == nil, "list: unknown id returns nil")

-- === list_tab_pty_ids: floating/overlay pane excluded ===

do
    local tab = { id = 1, root = mock_pane(1), last_focused_id = 1 }
    tab.floating = { pane = mock_pane(2), visible = true }
    t.set_state({
        tabs = { tab },
        active_tab = 1,
        focused_id = 1,
    })
end
assert(tiling.list_tab_pty_ids(2) == nil, "list: floating pane id returns nil")
ids = tiling.list_tab_pty_ids(1)
assert(ids ~= nil and #ids == 1 and ids[1] == 1, "list: query for tree root ignores floating")

-- === break_pane: moves pane out to a new tab ===

t.set_state({
    tabs = {
        {
            id = 1,
            root = mock_split(10, "row", {
                mock_pane(1),
                mock_pane(2),
            }),
            last_focused_id = 1,
        },
    },
    active_tab = 1,
    focused_id = 1,
    next_tab_id = 2,
})
tiling.update({ type = "break_pane", data = { pty_id = 2 } })
local s = t.get_state()
assert(#s.tabs == 2, "break: source tab expanded into 2 tabs, got " .. tostring(#s.tabs))
-- Source tab (tab 1) should have just pane 1 now — the split with one
-- child was collapsed by remove_pane_recursive.
assert(s.tabs[1].root.type == "pane", "break: source root collapsed to single pane")
assert(s.tabs[1].root.id == 1, "break: source root is the surviving pane")
-- New tab is appended.
assert(s.tabs[2].root.type == "pane", "break: new tab root is a pane")
assert(s.tabs[2].root.id == 2, "break: new tab root is the moved pane")
assert(s.tabs[2].last_focused_id == 2, "break: new tab last_focused_id tracks moved pane")

-- === break_pane with was_active=true: focus follows ===

t.set_state({
    tabs = {
        {
            id = 1,
            root = mock_split(10, "row", {
                mock_pane(1),
                mock_pane(2),
            }),
            last_focused_id = 1,
        },
    },
    active_tab = 1,
    focused_id = 1,
    next_tab_id = 2,
})
tiling.update({ type = "break_pane", data = { pty_id = 2 } })
s = t.get_state()
assert(s.active_tab == 2, "break active: active_tab moved to new tab, got " .. tostring(s.active_tab))
assert(s.focused_id == 2, "break active: focus moved to moved pane, got " .. tostring(s.focused_id))

-- === break_pane with was_active=false: no focus steal ===

t.set_state({
    tabs = {
        {
            id = 1,
            root = mock_split(10, "row", {
                mock_pane(1),
                mock_pane(2),
            }),
            last_focused_id = 1,
        },
        { id = 2, root = mock_pane(99), last_focused_id = 99 },
    },
    active_tab = 2,
    focused_id = 99,
    next_tab_id = 3,
})
tiling.update({ type = "break_pane", data = { pty_id = 2 } })
s = t.get_state()
assert(s.active_tab == 2, "break inactive: active_tab unchanged, got " .. tostring(s.active_tab))
assert(s.focused_id == 99, "break inactive: focus unchanged, got " .. tostring(s.focused_id))
assert(#s.tabs == 3, "break inactive: new tab appended")
assert(s.tabs[3].root.id == 2, "break inactive: moved pane is in the new tab")

-- === break_pane clears global state.zoomed_pane_id if it was the moved pane ===

t.set_state({
    tabs = {
        {
            id = 1,
            root = mock_split(10, "row", {
                mock_pane(1),
                mock_pane(2),
            }),
            last_focused_id = 2,
        },
    },
    active_tab = 1,
    focused_id = 2,
    zoomed_pane_id = 2,
    next_tab_id = 2,
})
tiling.update({ type = "break_pane", data = { pty_id = 2 } })
s = t.get_state()
assert(s.zoomed_pane_id == nil, "break: global zoom cleared for moved pane")

-- === break_pane clears per-tab zoomed_pane_id across all tabs ===

t.set_state({
    tabs = {
        { id = 1, root = mock_pane(99), last_focused_id = 99 },
        {
            id = 2,
            root = mock_split(10, "row", {
                mock_pane(1),
                mock_pane(2),
            }),
            last_focused_id = 2,
            zoomed_pane_id = 2,
        },
    },
    active_tab = 1,
    focused_id = 99,
    next_tab_id = 3,
})
tiling.update({ type = "break_pane", data = { pty_id = 2 } })
s = t.get_state()
assert(s.tabs[2].zoomed_pane_id == nil, "break: per-tab zoom cleared when moved pane was zoomed")

-- === break_pane fixes src_tab.last_focused_id when it pointed at the moved pane ===

t.set_state({
    tabs = {
        {
            id = 1,
            root = mock_split(10, "row", {
                mock_pane(1),
                mock_pane(2),
            }),
            last_focused_id = 2,
        },
        { id = 2, root = mock_pane(99), last_focused_id = 99 },
    },
    active_tab = 2,
    focused_id = 99,
    next_tab_id = 3,
})
tiling.update({ type = "break_pane", data = { pty_id = 2 } })
s = t.get_state()
assert(
    s.tabs[1].last_focused_id == 1,
    "break: source last_focused_id retargeted, got " .. tostring(s.tabs[1].last_focused_id)
)

-- === break_pane on solo pane: no-op ===

t.set_state({
    tabs = {
        { id = 1, root = mock_pane(1), last_focused_id = 1 },
    },
    active_tab = 1,
    focused_id = 1,
    next_tab_id = 2,
})
tiling.update({ type = "break_pane", data = { pty_id = 1 } })
s = t.get_state()
assert(#s.tabs == 1, "break solo: no new tab created")
assert(s.tabs[1].root.id == 1, "break solo: original pane untouched")

-- === break_pane on unknown pty_id: no-op ===

t.set_state({
    tabs = {
        {
            id = 1,
            root = mock_split(10, "row", {
                mock_pane(1),
                mock_pane(2),
            }),
            last_focused_id = 1,
        },
    },
    active_tab = 1,
    focused_id = 1,
    next_tab_id = 2,
})
tiling.update({ type = "break_pane", data = { pty_id = 999 } })
s = t.get_state()
assert(#s.tabs == 1, "break unknown: no new tab created")
assert(s.tabs[1].root.type == "split", "break unknown: source tree unchanged")

-- === break_pane on a floating/overlay pane: no-op ===

do
    local tab = {
        id = 1,
        root = mock_split(10, "row", {
            mock_pane(1),
            mock_pane(2),
        }),
        last_focused_id = 1,
    }
    tab.floating = { pane = mock_pane(77), visible = true }
    t.set_state({
        tabs = { tab },
        active_tab = 1,
        focused_id = 1,
        next_tab_id = 2,
    })
end
tiling.update({ type = "break_pane", data = { pty_id = 77 } })
s = t.get_state()
assert(#s.tabs == 1, "break floating: floating pane is untreatable, no new tab")
assert(s.tabs[1].floating ~= nil, "break floating: floating pane still attached to tab")
assert(s.tabs[1].floating.pane.id == 77, "break floating: floating pane identity preserved")
