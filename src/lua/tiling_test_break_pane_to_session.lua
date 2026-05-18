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
-- Per fn-45 matrix-wins semantics: both remove AND place target the SOURCE
-- session ("alpha"). Viewer's state.tabs is NOT mutated.

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
        cwd = "/Users/mike/code/alpha",
        focus = false,
    },
})
assert(happy_ret == true, "break_pane_to_session happy: returns true on success")
assert(#remove_calls == 1, "break_pane_to_session happy: remove_pty_from_session called exactly once")
assert(remove_calls[1].session_name == "alpha", "break_pane_to_session happy: remove targets source_session")
assert(remove_calls[1].pty_id == 42, "break_pane_to_session happy: remove gets correct pty_id")
-- fn-45 matrix-wins: place targets the SOURCE session, not the viewer's.
assert(#place_calls == 1, "break_pane_to_session happy: place_pty_in_session called exactly once")
assert(
    place_calls[1].session_name == "alpha",
    "break_pane_to_session happy: place targets source_session (matrix-wins)"
)
assert(place_calls[1].pty_id == 42, "break_pane_to_session happy: place gets correct pty_id")
assert(place_calls[1].cwd == "/Users/mike/code/alpha", "break_pane_to_session happy: place gets cwd")
-- Viewer's state.tabs is left untouched — no in-memory mutation, no save.
local hs = t.get_state()
assert(#hs.tabs == 1, "break_pane_to_session happy: viewer state.tabs unchanged (matrix-wins)")
assert(hs.tabs[1].root.id == 500, "break_pane_to_session happy: original viewer tab untouched")
assert(save_calls == 0, "break_pane_to_session happy: viewer's prise.save() NOT called (no viewer mutation)")

-- === break_pane_to_session: remove_return=false bail — no place call ===

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
        cwd = "/Users/mike/code/alpha",
        focus = false,
    },
})
assert(remove_fail_ret == false, "break_pane_to_session remove-fail: returns false when remove fails")
assert(#remove_calls == 1, "break_pane_to_session remove-fail: remove was attempted")
assert(#place_calls == 0, "break_pane_to_session remove-fail: place NOT called when remove fails")
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

-- === break_pane_to_session: place_return=false orphan — warn but no rollback ===

reset_captures()
place_return = false
t.set_state({
    tabs = {
        { id = 1, root = mock_pane(500), last_focused_id = 500 },
    },
    active_tab = 1,
    focused_id = 500,
    next_tab_id = 2,
})
local place_fail_ret = tiling.update({
    type = "break_pane",
    data = {
        pty_id = 42,
        source_session = "alpha",
        cwd = "/Users/mike/code/alpha",
        focus = false,
    },
})
assert(place_fail_ret == false, "break_pane_to_session place-fail: returns false when place fails")
assert(#remove_calls == 1, "break_pane_to_session place-fail: remove was called")
assert(#place_calls == 1, "break_pane_to_session place-fail: place was attempted")
local pfs = t.get_state()
assert(#pfs.tabs == 1, "break_pane_to_session place-fail: viewer state unchanged after orphan")
assert(#warn_calls == 1, "break_pane_to_session place-fail: one warn logged")
assert(
    warn_calls[1]:find("cross-session place failed", 1, true),
    "break_pane_to_session place-fail: warn mentions cross-session place"
)
assert(
    warn_calls[1]:find("orphaned after remove", 1, true),
    "break_pane_to_session place-fail: warn mentions orphan condition"
)

-- === break_pane_to_session: missing cwd — fail visibly without remove ===

reset_captures()
t.set_state({
    tabs = {
        { id = 1, root = mock_pane(500), last_focused_id = 500 },
    },
    active_tab = 1,
    focused_id = 500,
    next_tab_id = 2,
})
local no_cwd_ret = tiling.update({
    type = "break_pane",
    data = {
        pty_id = 42,
        source_session = "alpha",
        -- cwd intentionally omitted
        focus = false,
    },
})
assert(no_cwd_ret == false, "break_pane_to_session no-cwd: returns false when cwd missing")
assert(#remove_calls == 0, "break_pane_to_session no-cwd: remove NOT called when cwd missing (avoid orphan)")
assert(#place_calls == 0, "break_pane_to_session no-cwd: place NOT called when cwd missing")
assert(#warn_calls == 1, "break_pane_to_session no-cwd: warn logged")
assert(
    warn_calls[1]:find("missing cwd", 1, true),
    "break_pane_to_session no-cwd: warn mentions missing cwd"
)

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
-- Viewer isolation invariant (fn-45-fix-b5-cross-session-break.1)
-- ========================================================================
-- Cross-session breaks land in the SOURCE session's JSON via the file-based
-- pair (remove_pty_from_session + place_pty_in_session). The viewer's
-- state.tabs and active_tab MUST remain untouched regardless of the viewer's
-- pre-break tab layout. These tests pin that invariant for the
-- multi-tab-viewer and empty-viewer cases that previously asserted
-- in-memory placement into the viewer's session.

-- === viewer isolation: cross-session break with multi-tab viewer ===

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
        cwd = "/Users/mike/code/alpha",
        focus = false,
    },
})
assert(multi_tab_ret == true, "viewer-isolation multi-tab: returns true on success")
assert(#place_calls == 1, "viewer-isolation multi-tab: place called once")
assert(place_calls[1].session_name == "alpha", "viewer-isolation multi-tab: place targets source 'alpha', not viewer")
local mhs = t.get_state()
-- Viewer's tabs are NOT touched: same count, same identities, same active_tab.
assert(#mhs.tabs == 3, "viewer-isolation multi-tab: viewer tab count unchanged (3)")
assert(mhs.active_tab == 2, "viewer-isolation multi-tab: viewer active_tab unchanged (2)")
assert(mhs.tabs[1].id == 1, "viewer-isolation multi-tab: tab 1 unchanged")
assert(mhs.tabs[2].id == 2, "viewer-isolation multi-tab: tab 2 unchanged")
assert(mhs.tabs[3].id == 3, "viewer-isolation multi-tab: tab 3 unchanged (NOT pushed)")
assert(save_calls == 0, "viewer-isolation multi-tab: viewer save NOT called")

-- === viewer isolation: cross-session break with empty viewer ===

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
        cwd = "/Users/mike/code/other",
        focus = false,
    },
})
assert(empty_ret == true, "viewer-isolation empty: returns true on success")
assert(#place_calls == 1, "viewer-isolation empty: place called once")
assert(place_calls[1].session_name == "other", "viewer-isolation empty: place targets source 'other'")
local ehs = t.get_state()
-- Viewer remains empty — no inadvertent tab insertion into the viewer.
assert(#ehs.tabs == 0, "viewer-isolation empty: viewer state.tabs remains empty")
assert(save_calls == 0, "viewer-isolation empty: viewer save NOT called")
