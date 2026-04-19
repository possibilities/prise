-- Tests for the cross-session break_pane extension (source_session field).
-- Covers the four scenarios mirroring tiling_test_move_pane_to_session.lua:
--   1. Happy path: remove + place both succeed, returns true.
--   2. remove_return=false bail: remove fails, place NOT called, returns false.
--   3. place_return=false orphan: remove succeeds, place fails, returns false.
--   4. Back-compat: absent source_session falls through to existing same-session path.
--
-- Mocks are constructed inline per the 2026-04-11 test_helpers phase-out
-- policy: new test files must never introduce new consumers of the shared
-- helper module.

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

-- Capture buffers populated by stubs. Tests call reset_captures() before
-- each scenario so assertions see only the current run's effects.
local remove_calls = {}
local remove_return = true
local place_calls = {}
local place_return = true
local warn_calls = {}
local save_calls = 0
local current_session = "viewer"

local mock_prise = {
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
    save = function()
        save_calls = save_calls + 1
    end,
    exit = function() end,
    get_session_name = function()
        return current_session
    end,
    attach = function() end,
    switch_session = function()
        return true
    end,
    rename_session = function() end,
    create_session = function() end,
    remove_pty_from_session = function(session_name, pty_id)
        table.insert(remove_calls, {
            session_name = session_name,
            pty_id = pty_id,
        })
        return remove_return
    end,
    place_pty_in_session = function(session_name, pty_id, cwd, tab_title)
        table.insert(place_calls, {
            session_name = session_name,
            pty_id = pty_id,
            cwd = cwd,
            tab_title = tab_title,
        })
        return place_return
    end,
    create_text_input = function()
        return {
            text = function()
                return ""
            end,
            clear = function() end,
            insert = function() end,
        }
    end,
    log = {
        debug = function() end,
        info = function() end,
        warn = function(msg)
            table.insert(warn_calls, msg)
        end,
        error = function() end,
    },
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
package.loaded["prise"] = mock_prise

local tiling = require("tiling")
local t = tiling._test

---Zero out all capture buffers so a scenario sees only its own effects.
local function reset_captures()
    remove_calls = {}
    remove_return = true
    place_calls = {}
    place_return = true
    warn_calls = {}
    save_calls = 0
    current_session = "viewer"
end

-- === break_pane_to_session happy path: viewer on unrelated session ===
-- Pane 42 lives in session "alpha" (not in viewer's state.tabs).
-- Viewer is on "viewer" (unrelated to both source and destination).
-- remove_pty_from_session("alpha", 42) and an in-memory tab insertion should
-- both fire; returns true.

reset_captures()
t.set_state({
    tabs = {
        { id = 1, root = mock_pane(500), last_focused_id = 500 },
    },
    active_tab = 1,
    focused_id = 500,
    next_tab_id = 2,
})
local happy_ret = tiling.update({
    type = "break_pane",
    data = {
        pty_id = 42, -- not in viewer state
        source_session = "alpha",
        focus = false,
    },
})
assert(happy_ret == true, "break_pane_to_session happy: returns true on success")
assert(#remove_calls == 1, "break_pane_to_session happy: remove_pty_from_session called exactly once")
assert(remove_calls[1].session_name == "alpha", "break_pane_to_session happy: remove targets source_session")
assert(remove_calls[1].pty_id == 42, "break_pane_to_session happy: remove gets correct pty_id")
-- Viewer is on the current session ("viewer") which is where the break lands;
-- the handler inserts the new tab in-memory instead of calling place_pty_in_session.
local hs = t.get_state()
assert(#hs.tabs == 2, "break_pane_to_session happy: new tab inserted into viewer state")
assert(hs.tabs[2].last_focused_id == 42, "break_pane_to_session happy: new tab last_focused_id is broken pane")
assert(save_calls >= 1, "break_pane_to_session happy: prise.save() called")
-- Viewer tab count and contents for pre-existing tab are unchanged.
assert(hs.tabs[1].root.id == 500, "break_pane_to_session happy: original viewer tab untouched")

-- === break_pane_to_session: remove_return=false bail — no in-memory mutation ===

reset_captures()
remove_return = false
t.set_state({
    tabs = {
        { id = 1, root = mock_pane(500), last_focused_id = 500 },
    },
    active_tab = 1,
    focused_id = 500,
    next_tab_id = 2,
})
local remove_fail_ret = tiling.update({
    type = "break_pane",
    data = {
        pty_id = 42,
        source_session = "alpha",
        focus = false,
    },
})
assert(remove_fail_ret == false, "break_pane_to_session remove-fail: returns false when remove fails")
assert(#remove_calls == 1, "break_pane_to_session remove-fail: remove was attempted")
-- Viewer state must not be mutated after a failed remove.
local rfs = t.get_state()
assert(#rfs.tabs == 1, "break_pane_to_session remove-fail: no new tab inserted after failed remove")
assert(#warn_calls == 1, "break_pane_to_session remove-fail: one warning logged")
assert(
    warn_calls[1]:find("cross-session remove failed", 1, true),
    "break_pane_to_session remove-fail: warn mentions cross-session remove"
)
assert(warn_calls[1]:find("pty=42", 1, true), "break_pane_to_session remove-fail: warn mentions pty id")
assert(warn_calls[1]:find("source=alpha", 1, true), "break_pane_to_session remove-fail: warn mentions source session")

-- === break_pane_to_session: back-compat — absent source_session falls through ===
-- When source_session is not provided and the pane is not in viewer state,
-- the existing no-op behavior is preserved (returns false, no remove/place).

reset_captures()
t.set_state({
    tabs = {
        { id = 1, root = mock_pane(500), last_focused_id = 500 },
    },
    active_tab = 1,
    focused_id = 500,
    next_tab_id = 2,
})
local no_source_ret = tiling.update({
    type = "break_pane",
    data = {
        pty_id = 42, -- not in viewer state
        -- source_session intentionally omitted
        focus = false,
    },
})
assert(no_source_ret == false, "break_pane_to_session no-source: absent source_session returns false")
assert(#remove_calls == 0, "break_pane_to_session no-source: remove NOT called when source_session missing")
local nss = t.get_state()
assert(#nss.tabs == 1, "break_pane_to_session no-source: viewer state unchanged")

-- === break_pane_to_session: same-session path preserved when pane is in viewer ===
-- When source_session is absent and the pane IS in viewer's state.tabs, the
-- handler executes the same-session break normally and returns true.

reset_captures()
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
local same_session_ret = tiling.update({
    type = "break_pane",
    data = {
        pty_id = 2,
        -- no source_session: same-session break
    },
})
assert(same_session_ret == true, "break_pane_to_session back-compat: same-session break returns true")
assert(#remove_calls == 0, "break_pane_to_session back-compat: remove NOT called for same-session break")
local bcs = t.get_state()
assert(#bcs.tabs == 2, "break_pane_to_session back-compat: same-session break creates new tab")
assert(bcs.tabs[2].root.id == 2, "break_pane_to_session back-compat: moved pane in new tab")

-- ========================================================================
-- Right-of-focus placement policy (fn-32-break-pane-right-of-focus.1)
-- ========================================================================
-- Cross-session breaks must also land right-of-focus in the destination
-- session's state.tabs — the anchor rule is shared with the same-session
-- path. These tests exercise the cross-session insert and the empty-tabs
-- degenerate case where the handler's (#state.tabs == 0) → 1 branch
-- diverges from the anchor+1 rule.

-- === right-of-focus: cross-session break into viewer with multiple tabs ===
-- Viewer's destination session has 3 tabs with active_tab = 2. Break
-- pane 42 from session "alpha" (not in viewer state). Anchor = 2,
-- insert_idx = 3. New tab at index 3; viewer's active_tab unchanged at 2.

reset_captures()
t.set_state({
    tabs = {
        { id = 1, root = mock_pane(500), last_focused_id = 500 },
        { id = 2, root = mock_pane(501), last_focused_id = 501 },
        { id = 3, root = mock_pane(502), last_focused_id = 502 },
    },
    active_tab = 2,
    focused_id = 501,
    next_tab_id = 4,
})
local multi_tab_ret = tiling.update({
    type = "break_pane",
    data = {
        pty_id = 42,
        source_session = "alpha",
        focus = false,
    },
})
assert(multi_tab_ret == true, "right-of-focus cross-session: returns true on success")
local mhs = t.get_state()
assert(#mhs.tabs == 4, "right-of-focus cross-session: tab count is 4, got " .. tostring(#mhs.tabs))
assert(mhs.tabs[3].root.pty_id == 42, "right-of-focus cross-session: new tab at index 3 hosts broken pane (pty_id 42)")
assert(mhs.active_tab == 2, "right-of-focus cross-session: viewer active_tab unchanged, got " .. tostring(mhs.active_tab))
-- Verify the pre-existing tabs retained their identities in expected
-- positions: tabs 1 and 2 unchanged; tab 3 (originally pane 502) pushed
-- to index 4.
assert(mhs.tabs[1].id == 1, "right-of-focus cross-session: tab 1 unchanged")
assert(mhs.tabs[2].id == 2, "right-of-focus cross-session: tab 2 unchanged")
assert(mhs.tabs[4].id == 3, "right-of-focus cross-session: former tab 3 pushed to index 4")

-- === empty-tabs degenerate: cross-session break into empty viewer ===
-- #state.tabs = 0 (no tabs — viewer just attached to an empty destination
-- session). Cross-session break with the normalize formula would give
-- anchor+1 = 2, but the handler's (#state.tabs == 0) → 1 branch routes
-- the insert to index 1 so the new tab becomes the only tab.

reset_captures()
t.set_state({
    tabs = {},
    active_tab = 1,
    focused_id = nil,
    next_tab_id = 1,
})
local empty_ret = tiling.update({
    type = "break_pane",
    data = {
        pty_id = 77,
        source_session = "other",
        focus = false,
    },
})
assert(empty_ret == true, "empty-tabs: returns true on success")
local ehs = t.get_state()
assert(#ehs.tabs == 1, "empty-tabs: new tab lands as only tab, got " .. tostring(#ehs.tabs))
assert(ehs.tabs[1].root.pty_id == 77, "empty-tabs: new tab hosts the broken pane")
