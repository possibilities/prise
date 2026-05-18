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
    log = { debug = function() end, info = function() end, warn = function() end },
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
    -- Broker pattern's enabling primitive — fire-and-forget client→server
    -- notification. Replaced inline by individual tests via the
    -- `notify_calls` capture below to assert reply payload shape.
    notify = function() end,
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
-- Find the former source tab (id == 2) by iteration since the new
-- right-of-focus placement may have shifted its array index.
local src_tab_after = nil
for _, tab in ipairs(s.tabs) do
    if tab.id == 2 then
        src_tab_after = tab
        break
    end
end
assert(src_tab_after ~= nil, "break: source tab (id=2) still present after break")
assert(src_tab_after.zoomed_pane_id == nil, "break: per-tab zoom cleared when moved pane was zoomed")

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

-- === break_pane on solo main-tree pane with floating in multi-tab: no-op ===
-- The solo-pane guard prevents breaking the only tree pane even when
-- auxiliary panes exist, so floating panes are never orphaned.

do
    local tab1 = {
        id = 1,
        root = mock_pane(1),
        last_focused_id = 1,
    }
    tab1.floating = { pane = mock_pane(50), visible = true }
    t.set_state({
        tabs = {
            tab1,
            { id = 2, root = mock_pane(99), last_focused_id = 99 },
        },
        active_tab = 1,
        focused_id = 1,
        next_tab_id = 3,
    })
end
tiling.update({ type = "break_pane", data = { pty_id = 1 } })
s = t.get_state()
assert(#s.tabs == 2, "break solo-float: tab count unchanged")
assert(s.tabs[1].root.id == 1, "break solo-float: main-tree pane untouched")
assert(s.tabs[1].floating ~= nil, "break solo-float: floating pane still attached")
assert(s.tabs[1].floating.pane.id == 50, "break solo-float: floating pane identity preserved")

-- === break_pane with was_active=true AND focus=false: no focus steal ===
-- The caller opts out of focus-follow via data.focus=false. Source tab is
-- the active tab and the focused pane is a sibling of the moved pane, so
-- without the opt-out we'd yank focus to the new tab. With focus=false the
-- break is silent: active_tab and focused_id stay pinned to the sibling.

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
tiling.update({ type = "break_pane", data = { pty_id = 2, focus = false } })
s = t.get_state()
assert(s.active_tab == 1, "break active+focus=false: active_tab unchanged, got " .. tostring(s.active_tab))
assert(s.focused_id == 1, "break active+focus=false: focused_id unchanged, got " .. tostring(s.focused_id))
assert(#s.tabs == 2, "break active+focus=false: new tab still appended")
assert(s.tabs[2].root.id == 2, "break active+focus=false: moved pane landed in new tab")

-- === break_pane with was_active=true AND focus=true: focus still follows ===
-- Explicit focus=true matches default behavior — regression protection for
-- the opt-in path when callers want to be explicit about following.

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
tiling.update({ type = "break_pane", data = { pty_id = 2, focus = true } })
s = t.get_state()
assert(s.active_tab == 2, "break active+focus=true: active_tab moved to new tab, got " .. tostring(s.active_tab))
assert(s.focused_id == 2, "break active+focus=true: focus followed to moved pane, got " .. tostring(s.focused_id))

-- === break_pane with was_active=false AND focus=false: no-op on focus either way ===
-- When the source tab is inactive, follow_focus is a no-op — existing
-- behavior already leaves focus alone. Confirms the opt-out doesn't flip
-- any off-path behavior.

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
tiling.update({ type = "break_pane", data = { pty_id = 2, focus = false } })
s = t.get_state()
assert(s.active_tab == 2, "break inactive+focus=false: active_tab unchanged")
assert(s.focused_id == 99, "break inactive+focus=false: focus unchanged")
assert(#s.tabs == 3, "break inactive+focus=false: new tab inserted")
assert(s.tabs[3].root.id == 2, "break inactive+focus=false: moved pane is in the new tab")

-- ========================================================================
-- Right-of-focus placement policy (fn-32-break-pane-right-of-focus.1)
-- ========================================================================
-- The new tab is inserted immediately to the RIGHT of the focused tab
-- (state.active_tab), not appended to the end. The anchor is normalized
-- via max(1, min(#tabs, active_tab or 1)) with an explicit empty-tabs
-- → index 1 branch. Covers: active-tab source, inactive source, follow-
-- focus with captured anchor, the three normalize edges (nil / 0 /
-- overflow), and the empty-tabs degenerate case.

-- === right-of-focus: break pane in active tab (tab 2 of 3) lands at index 3 ===
-- 3 tabs, active_tab = 2, break pane in active tab. Anchor = 2,
-- insert_idx = 3. New tab at index 3; total tabs = 4.

t.set_state({
    tabs = {
        { id = 1, root = mock_pane(10), last_focused_id = 10 },
        {
            id = 2,
            root = mock_split(20, "row", {
                mock_pane(21),
                mock_pane(22),
            }),
            last_focused_id = 21,
        },
        { id = 3, root = mock_pane(30), last_focused_id = 30 },
    },
    active_tab = 2,
    focused_id = 21,
    next_tab_id = 4,
})
tiling.update({ type = "break_pane", data = { pty_id = 22 } })
s = t.get_state()
assert(#s.tabs == 4, "right-of-focus active: tab count is 4, got " .. tostring(#s.tabs))
assert(s.tabs[3].root.id == 22, "right-of-focus active: new tab at index 3 hosts moved pane")
assert(s.tabs[1].id == 1, "right-of-focus active: tab 1 unchanged")
assert(s.tabs[2].id == 2, "right-of-focus active: tab 2 (collapsed source) at index 2")
assert(s.tabs[4].id == 3, "right-of-focus active: former tab 3 pushed to index 4")

-- === right-of-focus: break pane in tab 1 (left of active) lands at index 3 ===
-- 3 tabs, active_tab = 2, break pane in tab 1 (inactive source, left of
-- active). Source split collapses to single pane; source tab survives.
-- Anchor = 2, insert_idx = 3. New tab at index 3; active_tab unchanged.

t.set_state({
    tabs = {
        {
            id = 1,
            root = mock_split(10, "row", {
                mock_pane(11),
                mock_pane(12),
            }),
            last_focused_id = 11,
        },
        { id = 2, root = mock_pane(20), last_focused_id = 20 },
        { id = 3, root = mock_pane(30), last_focused_id = 30 },
    },
    active_tab = 2,
    focused_id = 20,
    next_tab_id = 4,
})
tiling.update({ type = "break_pane", data = { pty_id = 12 } })
s = t.get_state()
assert(#s.tabs == 4, "right-of-focus inactive-left: tab count is 4, got " .. tostring(#s.tabs))
assert(s.tabs[3].root.id == 12, "right-of-focus inactive-left: new tab at index 3 hosts moved pane")
assert(s.active_tab == 2, "right-of-focus inactive-left: active_tab unchanged, got " .. tostring(s.active_tab))
assert(s.tabs[2].id == 2, "right-of-focus inactive-left: active tab still at index 2 (pointed at same logical tab)")
assert(
    s.tabs[1].id == 1 and s.tabs[1].root.type == "pane",
    "right-of-focus inactive-left: source tab collapsed to single pane at index 1"
)

-- === right-of-focus: was_active AND follow_focus uses captured anchor ===
-- 3 tabs, active_tab = 2, break pane 22 from active tab with default
-- focus=true. Anchor captured as 2 BEFORE mutation; new tab at index 3;
-- active_tab should be set to 3 via set_active_tab_index(anchor + 1),
-- NOT via #state.tabs (which would coincide here only because the
-- insertion happened at the end of a 3-tab state → 4-tab state; the
-- pre-mutation capture is still the only correct source per spec).

t.set_state({
    tabs = {
        { id = 1, root = mock_pane(10), last_focused_id = 10 },
        {
            id = 2,
            root = mock_split(20, "row", {
                mock_pane(21),
                mock_pane(22),
            }),
            last_focused_id = 21,
        },
        { id = 3, root = mock_pane(30), last_focused_id = 30 },
    },
    active_tab = 2,
    focused_id = 21,
    next_tab_id = 4,
})
tiling.update({ type = "break_pane", data = { pty_id = 22 } })
s = t.get_state()
assert(
    s.active_tab == 3,
    "right-of-focus follow-focus: active_tab set to insert_idx (3), got " .. tostring(s.active_tab)
)
assert(
    s.focused_id == 22,
    "right-of-focus follow-focus: focused pane is the moved pane, got " .. tostring(s.focused_id)
)
assert(s.tabs[3].root.id == 22, "right-of-focus follow-focus: new tab at index 3")

-- === normalize: state.active_tab = nil → anchor = 1, new tab at index 2 ===
-- 3 tabs, nil active_tab, break pane in (otherwise inactive) tab 2.
-- Anchor = max(1, min(3, nil or 1)) = 1; insert_idx = 2.

t.set_state({
    tabs = {
        { id = 1, root = mock_pane(10), last_focused_id = 10 },
        {
            id = 2,
            root = mock_split(20, "row", {
                mock_pane(21),
                mock_pane(22),
            }),
            last_focused_id = 21,
        },
        { id = 3, root = mock_pane(30), last_focused_id = 30 },
    },
    active_tab = nil,
    focused_id = 21,
    next_tab_id = 4,
})
tiling.update({ type = "break_pane", data = { pty_id = 22 } })
s = t.get_state()
assert(#s.tabs == 4, "normalize nil: tab count is 4, got " .. tostring(#s.tabs))
assert(s.tabs[2].root.id == 22, "normalize nil: new tab lands at index 2 (anchor + 1 where anchor=1)")
assert(s.tabs[1].id == 1, "normalize nil: tab 1 unchanged at index 1")

-- === normalize: state.active_tab = 0 → anchor = 1, new tab at index 2 ===
-- Same shape as nil case — zero routes through the max(1, ...) floor.

t.set_state({
    tabs = {
        { id = 1, root = mock_pane(10), last_focused_id = 10 },
        {
            id = 2,
            root = mock_split(20, "row", {
                mock_pane(21),
                mock_pane(22),
            }),
            last_focused_id = 21,
        },
        { id = 3, root = mock_pane(30), last_focused_id = 30 },
    },
    active_tab = 0,
    focused_id = 21,
    next_tab_id = 4,
})
tiling.update({ type = "break_pane", data = { pty_id = 22 } })
s = t.get_state()
assert(#s.tabs == 4, "normalize zero: tab count is 4, got " .. tostring(#s.tabs))
assert(s.tabs[2].root.id == 22, "normalize zero: new tab lands at index 2 (anchor + 1 where anchor=1)")

-- === normalize: state.active_tab = 99 (overflow) → anchor = 3, new tab at end ===
-- 3 tabs, active_tab = 99. Anchor = max(1, min(3, 99)) = 3; insert_idx = 4.
-- New tab is at end (equivalent to old append-to-end behavior for
-- overflow inputs only — this is intentional and documented).

t.set_state({
    tabs = {
        { id = 1, root = mock_pane(10), last_focused_id = 10 },
        {
            id = 2,
            root = mock_split(20, "row", {
                mock_pane(21),
                mock_pane(22),
            }),
            last_focused_id = 21,
        },
        { id = 3, root = mock_pane(30), last_focused_id = 30 },
    },
    active_tab = 99,
    focused_id = 21,
    next_tab_id = 4,
})
tiling.update({ type = "break_pane", data = { pty_id = 22 } })
s = t.get_state()
assert(#s.tabs == 4, "normalize overflow: tab count is 4, got " .. tostring(#s.tabs))
assert(s.tabs[4].root.id == 22, "normalize overflow: new tab lands at index 4 (anchor + 1 where anchor=3)")

-- Empty-tabs degenerate case (cross-session break into empty viewer) is
-- only reachable through the feat/break-pane-to-session branch's cross-
-- session extension. That coverage lives in tiling_test_break_pane_to_
-- session.lua on that branch. Here on feat/break-pane the handler early-
-- returns on `not src_tab`, so an empty state.tabs never reaches the
-- insertion path.

-- ========================================================================
-- classify_break_pane: structured reason taxonomy
-- ========================================================================
-- Covers all five return tokens: "ok", "solo_pane", "pty_not_tileable",
-- "pty_not_in_session", and "pty_not_found".

-- === classify: "ok" — pty in tile tree, tab has 2+ panes ===

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
})
assert(
    tiling.classify_break_pane(1) == "ok",
    "classify: multi-pane tile tree returns 'ok', got " .. tostring(tiling.classify_break_pane(1))
)
assert(
    tiling.classify_break_pane(2) == "ok",
    "classify: other pane in multi-pane tree also 'ok', got " .. tostring(tiling.classify_break_pane(2))
)

-- === classify: "solo_pane" — pty is the only pane in its tab's tile tree ===

t.set_state({
    tabs = {
        { id = 1, root = mock_pane(42), last_focused_id = 42 },
    },
    active_tab = 1,
    focused_id = 42,
})
assert(
    tiling.classify_break_pane(42) == "solo_pane",
    "classify: sole root pane returns 'solo_pane', got " .. tostring(tiling.classify_break_pane(42))
)

-- === classify: "pty_not_tileable" — pty lives in a floating slot only ===

do
    local tab = { id = 1, root = mock_pane(1), last_focused_id = 1 }
    tab.floating = { pane = mock_pane(77), visible = true }
    t.set_state({
        tabs = { tab },
        active_tab = 1,
        focused_id = 1,
    })
end
assert(
    tiling.classify_break_pane(77) == "pty_not_tileable",
    "classify: floating pane returns 'pty_not_tileable', got " .. tostring(tiling.classify_break_pane(77))
)

-- === classify: "pty_not_in_session" — in state.ptys but not in any tab ===
-- state.ptys is not present in v1 live runtime; injected here via the
-- direct state reference to exercise the cross-session token.

t.set_state({
    tabs = {
        { id = 1, root = mock_pane(1), last_focused_id = 1 },
    },
    active_tab = 1,
    focused_id = 1,
})
-- Inject a pty into state.ptys that doesn't appear in any tab tree.
local raw_state = t.get_state()
raw_state.ptys = { [99] = mock_pane(99) }
assert(
    tiling.classify_break_pane(99) == "pty_not_in_session",
    "classify: pty known via state.ptys but absent from tabs returns 'pty_not_in_session', got "
        .. tostring(tiling.classify_break_pane(99))
)
-- Clean up so subsequent tests get a fresh state.
raw_state.ptys = nil

-- === classify: "pty_not_found" — completely unknown pty_id ===

t.set_state({
    tabs = {
        { id = 1, root = mock_pane(1), last_focused_id = 1 },
    },
    active_tab = 1,
    focused_id = 1,
})
assert(
    tiling.classify_break_pane(999) == "pty_not_found",
    "classify: unknown id returns 'pty_not_found', got " .. tostring(tiling.classify_break_pane(999))
)

-- ========================================================================
-- commands-table Break Pane action closure
-- ========================================================================
-- The Break Pane entry in the commands table resolves state.focused_id
-- and dispatches M.update({type="break_pane", data={pty_id, focus=true}}).
-- When focused_id is nil the closure is a silent no-op (warn only).

-- === commands Break Pane: dispatches break_pane event for focused pane ===

t.set_state({
    tabs = {
        {
            id = 1,
            root = mock_split(10, "row", {
                mock_pane(5),
                mock_pane(6),
            }),
            last_focused_id = 5,
        },
    },
    active_tab = 1,
    focused_id = 5,
    next_tab_id = 2,
})
-- Invoke the Break Pane command via the keybind action_handler, which
-- mirrors the commands-table closure exactly.
t.action_handlers.break_pane()
s = t.get_state()
assert(#s.tabs == 2, "commands Break Pane: break dispatched — 2 tabs after break")
assert(s.tabs[2].root.id == 5, "commands Break Pane: focused pane moved to new tab")

-- === commands Break Pane: no-op (silent warn) when focused_id is nil ===

t.set_state({
    tabs = {
        { id = 1, root = mock_pane(1), last_focused_id = 1 },
    },
    active_tab = 1,
    focused_id = nil,
    next_tab_id = 2,
})
t.action_handlers.break_pane()
s = t.get_state()
assert(#s.tabs == 1, "commands Break Pane: nil focus is no-op, tab count unchanged")

-- ========================================================================
-- broker pattern: handle_break_pane_request + handle_break_pane_applied
-- ========================================================================
-- Lua-side half of fn-388-break-pane-rpc-broker-pattern. The server picks
-- one attached client (lowest stable Client.id) as broker; that client
-- runs handle_break_pane_request — classify + apply on "ok" + reply via
-- prise.notify("break_pane_reply", ...). Other attached clients receive
-- a fanout broadcast and re-apply via handle_break_pane_applied so
-- their tile-tree mirror catches up.
--
-- Defensive guard contract: both handlers build the inner break_pane
-- `data` table from primitives only — exactly { pty_id, focus }. The
-- cross-session arm at tiling.lua:3380's `if not src_tab` branch
-- references nil-on-feat/break-pane globals
-- (prise.remove_pty_from_session / prise.place_pty_in_session) and only
-- fires when event.data.source_session is a non-empty string. With a
-- two-field clean data table the bomb stays asleep.

-- === capture helper: replace prise.notify so we can assert the reply ===
-- The tiling module captured `prise` via `local prise = require("prise")`
-- at module load. We swap into the same shared mock table here so the
-- tiling.lua call site sees our capture function.

local prise_mock = package.loaded["prise"]
local notify_calls = {}
local original_notify = prise_mock.notify
local function install_notify_capture()
    notify_calls = {}
    prise_mock.notify = function(method, params)
        table.insert(notify_calls, { method = method, params = params })
    end
end
local function restore_notify()
    prise_mock.notify = original_notify
end

-- === handle_break_pane_request: happy path ("ok" verdict) ===

install_notify_capture()
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
tiling.handle_break_pane_request(2, true, 42)
s = t.get_state()
assert(#s.tabs == 2, "broker happy: state mutated — pane broken into new tab")
assert(s.tabs[2].root.id == 2, "broker happy: new tab root is the moved pane")
assert(#notify_calls == 1, "broker happy: prise.notify called exactly once")
assert(notify_calls[1].method == "break_pane_reply", "broker happy: method is break_pane_reply")
assert(notify_calls[1].params.request_id == 42, "broker happy: request_id echoed verbatim")
assert(notify_calls[1].params.ok == true, "broker happy: ok=true on successful classify")
assert(notify_calls[1].params.reason == "ok", "broker happy: reason='ok'")
restore_notify()

-- === handle_break_pane_request: solo_pane refusal ===

install_notify_capture()
t.set_state({
    tabs = {
        { id = 1, root = mock_pane(42), last_focused_id = 42 },
    },
    active_tab = 1,
    focused_id = 42,
    next_tab_id = 2,
})
tiling.handle_break_pane_request(42, true, 7)
s = t.get_state()
assert(#s.tabs == 1, "broker solo: state UNCHANGED (no apply on refusal)")
assert(s.tabs[1].root.id == 42, "broker solo: surviving pane untouched")
assert(#notify_calls == 1, "broker solo: prise.notify called exactly once")
assert(notify_calls[1].method == "break_pane_reply", "broker solo: method is break_pane_reply")
assert(notify_calls[1].params.request_id == 7, "broker solo: request_id echoed")
assert(notify_calls[1].params.ok == false, "broker solo: ok=false on refusal")
assert(notify_calls[1].params.reason == "solo_pane", "broker solo: reason='solo_pane'")
restore_notify()

-- === handle_break_pane_request: pty_not_found refusal ===

install_notify_capture()
t.set_state({
    tabs = {
        { id = 1, root = mock_pane(1), last_focused_id = 1 },
    },
    active_tab = 1,
    focused_id = 1,
    next_tab_id = 2,
})
tiling.handle_break_pane_request(999, true, 13)
s = t.get_state()
assert(#s.tabs == 1, "broker not_found: state UNCHANGED")
assert(s.tabs[1].root.id == 1, "broker not_found: surviving pane untouched")
assert(#notify_calls == 1, "broker not_found: prise.notify called exactly once")
assert(notify_calls[1].method == "break_pane_reply", "broker not_found: method")
assert(notify_calls[1].params.request_id == 13, "broker not_found: request_id echoed")
assert(notify_calls[1].params.ok == false, "broker not_found: ok=false")
assert(notify_calls[1].params.reason == "pty_not_found", "broker not_found: reason='pty_not_found'")
restore_notify()

-- === handle_break_pane_request: defensive guard against cross-session bomb ===
-- Wrap M.update to capture the event arg; verify data table has exactly
-- two keys (pty_id, focus) and no source_session/cwd/tab_title.

do
    install_notify_capture()
    local captured_event = nil
    local original_update = tiling.update
    tiling.update = function(event)
        captured_event = event
        return original_update(event)
    end

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
    tiling.handle_break_pane_request(2, true, 99)

    tiling.update = original_update
    restore_notify()

    assert(captured_event ~= nil, "guard: M.update was called")
    assert(captured_event.type == "break_pane", "guard: event.type is break_pane")
    assert(captured_event.data ~= nil, "guard: event.data present")
    assert(captured_event.data.pty_id == 2, "guard: pty_id passed through")
    assert(captured_event.data.focus == true, "guard: focus passed through")
    assert(captured_event.data.source_session == nil, "guard: NO source_session leaked")
    assert(captured_event.data.cwd == nil, "guard: NO cwd leaked")
    assert(captured_event.data.tab_title == nil, "guard: NO tab_title leaked")
    -- Belt-and-suspenders: count the keys to catch any future field additions.
    local key_count = 0
    for _ in pairs(captured_event.data) do
        key_count = key_count + 1
    end
    assert(key_count == 2, "guard: data has exactly two keys, got " .. tostring(key_count))
end

-- === handle_break_pane_applied: convergence happy path ===
-- Non-broker client receives the broadcast and re-applies the same
-- mutation. State mirrors what the broker did.

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
tiling.handle_break_pane_applied(2, true)
s = t.get_state()
assert(#s.tabs == 2, "applied happy: state converged — new tab inserted")
assert(s.tabs[2].root.id == 2, "applied happy: new tab root is the moved pane")
assert(s.tabs[1].root.type == "pane", "applied happy: source tab collapsed to single pane")
assert(s.tabs[1].root.id == 1, "applied happy: surviving pane is pane 1")

-- === handle_break_pane_applied: pty unknown to this client (idempotent) ===
-- Client B is attached to a different session and doesn't know pty_id
-- from the broadcast. M.update's break_pane arm sees `not src_tab` and
-- (with no source_session) falls through `return false` cleanly.

do
    t.set_state({
        tabs = {
            { id = 1, root = mock_pane(100), last_focused_id = 100 },
        },
        active_tab = 1,
        focused_id = 100,
        next_tab_id = 2,
    })
    -- pty_id 999 is not in any tab; should be a clean no-op.
    local ok, err = pcall(tiling.handle_break_pane_applied, 999, true)
    assert(ok, "applied unknown: no crash on pty unknown to client, err=" .. tostring(err))
    s = t.get_state()
    assert(#s.tabs == 1, "applied unknown: state untouched")
    assert(s.tabs[1].root.id == 100, "applied unknown: surviving pane unchanged")
end

-- === handle_break_pane_applied: defensive guard ===
-- Same defensive contract as handle_break_pane_request — clean two-field
-- data table to keep the cross-session bomb asleep.

do
    local captured_event = nil
    local original_update = tiling.update
    tiling.update = function(event)
        captured_event = event
        return original_update(event)
    end

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
    tiling.handle_break_pane_applied(2, false)

    tiling.update = original_update

    assert(captured_event ~= nil, "applied guard: M.update was called")
    assert(captured_event.type == "break_pane", "applied guard: event.type is break_pane")
    assert(captured_event.data.pty_id == 2, "applied guard: pty_id")
    assert(captured_event.data.focus == false, "applied guard: focus passed through")
    assert(captured_event.data.source_session == nil, "applied guard: NO source_session")
    local key_count = 0
    for _ in pairs(captured_event.data) do
        key_count = key_count + 1
    end
    assert(key_count == 2, "applied guard: exactly two keys, got " .. tostring(key_count))
end
