-- Tests for the move_pane_to_session event handler.
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

---Mock pane whose pty tracks close() calls.
local function mock_tracked_close_pane(id)
    local pty = mock_pty(id)
    pty._closed = false
    pty.close = function()
        pty._closed = true
    end
    return { type = "pane", id = id, pty = pty }
end

local function mock_split(id, direction, children)
    return { type = "split", split_id = id, direction = direction, children = children }
end

-- Capture buffers populated by the stubs below. Tests reset these before
-- each scenario so assertions see only the current run.
local place_calls = {}
local place_return = true
local warn_calls = {}
local save_calls = 0
local delete_calls = {}
local delete_return = true
local switch_calls = {}
local session_name_return = "test"
local list_sessions_return = {}

-- Install the prise mock module before loading tiling. Kept in scope as
-- `mock_prise` so scenarios can swap out place_return or inspect state.
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
        return session_name_return
    end,
    attach = function() end,
    switch_session = function(name)
        table.insert(switch_calls, name)
        return true
    end,
    rename_session = function() end,
    create_session = function() end,
    delete_session = function(session_name)
        table.insert(delete_calls, session_name)
        return delete_return
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
        return list_sessions_return
    end,
}
package.loaded["prise"] = mock_prise

local tiling = require("tiling")
local t = tiling._test

---Zero out all capture buffers so a scenario sees only its own effects.
local function reset_captures()
    place_calls = {}
    place_return = true
    warn_calls = {}
    save_calls = 0
    delete_calls = {}
    delete_return = true
    switch_calls = {}
    session_name_return = "test"
    list_sessions_return = {}
end

-- === Happy path: 2-pane tab, move one, source tab survives ===

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
tiling.update({
    type = "move_pane_to_session",
    data = {
        pty_id = 2,
        session_name = "foo",
        cwd = "/home/user/code/foo",
        tab_title = "my-claude",
    },
})
local s = t.get_state()
assert(#s.tabs == 1, "happy: source tab count unchanged, got " .. tostring(#s.tabs))
assert(s.tabs[1].root.type == "pane", "happy: source root collapsed to single pane")
assert(s.tabs[1].root.id == 1, "happy: survivor is the non-moved pane")
assert(#place_calls == 1, "happy: place_pty_in_session called exactly once")
assert(place_calls[1].session_name == "foo", "happy: session_name forwarded")
assert(place_calls[1].pty_id == 2, "happy: pty_id forwarded")
assert(place_calls[1].cwd == "/home/user/code/foo", "happy: cwd forwarded")
assert(place_calls[1].tab_title == "my-claude", "happy: tab_title forwarded")
assert(save_calls == 1, "happy: prise.save called")
assert(#warn_calls == 0, "happy: no warnings logged")

-- === Source tab empties: solo pane in a multi-tab session ===

reset_captures()
t.set_state({
    tabs = {
        { id = 1, root = mock_pane(1), last_focused_id = 1 },
        { id = 2, root = mock_pane(99), last_focused_id = 99 },
    },
    active_tab = 2,
    focused_id = 99,
    next_tab_id = 3,
})
tiling.update({
    type = "move_pane_to_session",
    data = {
        pty_id = 1,
        session_name = "bar",
        cwd = "/tmp/bar",
        tab_title = "solo",
    },
})
s = t.get_state()
assert(#s.tabs == 1, "empty: source tab dropped, got " .. tostring(#s.tabs))
assert(s.tabs[1].root.id == 99, "empty: surviving tab is the sibling")
-- src_tab_idx was 1, state.active_tab was 2 — removing idx 1 shifts the
-- active tab down to idx 1.
assert(s.active_tab == 1, "empty: active_tab shifted down")
assert(s.focused_id == 99, "empty: focus unchanged (was in sibling tab)")
assert(#place_calls == 1, "empty: place_pty_in_session called")
assert(place_calls[1].pty_id == 1, "empty: correct pty placed")

-- === Solo pane in the only tab: move succeeds, source session closes ===
-- fn-111: the old solo-pane-in-only-tab refusal was dropped. The primitive
-- now executes the move and cleans up the empty source session via
-- close_session. Mirrors tmux cmd-join-pane's server_kill_window-on-empty
-- pattern + wezterm's post-move is_dead cleanup.

reset_captures()
session_name_return = "alpha"
list_sessions_return = { "alpha", "bravo" }
t.set_state({
    tabs = {
        { id = 1, root = mock_pane(1), last_focused_id = 1 },
    },
    active_tab = 1,
    focused_id = 1,
    next_tab_id = 2,
})
tiling.update({
    type = "move_pane_to_session",
    data = {
        pty_id = 1,
        session_name = "bravo",
        cwd = "/tmp",
        tab_title = "t",
    },
})
s = t.get_state()
assert(#s.tabs == 0, "solo-only: source tab dropped (session drained)")
assert(#place_calls == 1, "solo-only: place_pty_in_session called exactly once")
assert(place_calls[1].session_name == "bravo", "solo-only: placed on destination")
assert(place_calls[1].pty_id == 1, "solo-only: correct pty placed")
-- close_session flushes a second save after delete; move's own save runs
-- first (source drain), then close_session (delete + viewer re-anchor +
-- save). save_calls == 2 reflects both boundaries.
assert(save_calls == 2, "solo-only: prise.save called by move AND close_session, got " .. tostring(save_calls))
assert(#delete_calls == 1, "solo-only: source session closed exactly once")
assert(delete_calls[1] == "alpha", "solo-only: close targets the source session")
assert(#switch_calls == 1, "solo-only: viewer re-anchored before close")
assert(switch_calls[1] == "bravo", "solo-only: viewer re-anchors to the remaining session")

-- === Floating/overlay guard: pane held on tab.floating ===

do
    reset_captures()
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
tiling.update({
    type = "move_pane_to_session",
    data = {
        pty_id = 77,
        session_name = "foo",
        cwd = "/tmp",
        tab_title = "float",
    },
})
s = t.get_state()
assert(s.tabs[1].floating ~= nil, "floating: floating pane still attached")
assert(s.tabs[1].floating.pane.id == 77, "floating: floating pane identity preserved")
assert(s.tabs[1].root.type == "split", "floating: tree tree unchanged")
assert(#place_calls == 0, "floating: place_pty_in_session NOT called")
assert(save_calls == 0, "floating: prise.save NOT called")

-- === Zoom state cleanup: global zoomed_pane_id cleared ===

reset_captures()
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
tiling.update({
    type = "move_pane_to_session",
    data = {
        pty_id = 2,
        session_name = "foo",
        cwd = "/tmp",
        tab_title = "zoom",
    },
})
s = t.get_state()
assert(s.zoomed_pane_id == nil, "zoom: global zoom cleared for moved pane")
assert(#place_calls == 1, "zoom: place_pty_in_session called")

-- === Per-tab zoom state cleanup across all tabs ===

reset_captures()
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
tiling.update({
    type = "move_pane_to_session",
    data = {
        pty_id = 2,
        session_name = "foo",
        cwd = "/tmp",
        tab_title = "pertab",
    },
})
s = t.get_state()
assert(s.tabs[2].zoomed_pane_id == nil, "zoom: per-tab zoom cleared when moved pane was zoomed")

-- === last_focused_id retargets when it pointed at the moved pane ===

reset_captures()
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
tiling.update({
    type = "move_pane_to_session",
    data = {
        pty_id = 2,
        session_name = "foo",
        cwd = "/tmp",
        tab_title = "refocus",
    },
})
s = t.get_state()
assert(
    s.tabs[1].last_focused_id == 1,
    "retarget: source last_focused_id retargeted, got " .. tostring(s.tabs[1].last_focused_id)
)
assert(s.focused_id == 99, "retarget: global focus unchanged (was in sibling tab)")

-- === place_pty_in_session failure: tree mutation still committed, warn logged ===

reset_captures()
place_return = false
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
tiling.update({
    type = "move_pane_to_session",
    data = {
        pty_id = 2,
        session_name = "foo",
        cwd = "/tmp",
        tab_title = "failcase",
    },
})
s = t.get_state()
assert(s.tabs[1].root.type == "pane", "fail: source tree still mutated (leaf removed)")
assert(s.tabs[1].root.id == 1, "fail: survivor still promoted")
assert(#place_calls == 1, "fail: place_pty_in_session was still invoked")
assert(#warn_calls == 1, "fail: exactly one warning logged, got " .. tostring(#warn_calls))
assert(warn_calls[1]:find("move_pane_to_session", 1, true), "fail: warning mentions move_pane_to_session")
assert(warn_calls[1]:find("pty=2", 1, true), "fail: warning mentions pty_id")
assert(warn_calls[1]:find("session=foo", 1, true), "fail: warning mentions session name")
assert(save_calls == 1, "fail: prise.save still called after mutation")

-- === was_active with was_focused: focus retargets in-place ===

reset_captures()
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
    next_tab_id = 2,
})
tiling.update({
    type = "move_pane_to_session",
    data = {
        pty_id = 2,
        session_name = "foo",
        cwd = "/tmp",
        tab_title = "focusmove",
    },
})
s = t.get_state()
assert(s.active_tab == 1, "focus-move: active_tab unchanged (survivor stays)")
assert(s.focused_id == 1, "focus-move: focus retargeted to survivor, got " .. tostring(s.focused_id))
assert(s.tabs[1].last_focused_id == 1, "focus-move: last_focused_id retargeted")

-- === Missing data fields: all variants are no-ops ===

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
-- Missing pty_id
tiling.update({
    type = "move_pane_to_session",
    data = { session_name = "foo", cwd = "/tmp", tab_title = "t" },
})
-- Missing session_name
tiling.update({
    type = "move_pane_to_session",
    data = { pty_id = 2, cwd = "/tmp", tab_title = "t" },
})
-- Empty session_name
tiling.update({
    type = "move_pane_to_session",
    data = { pty_id = 2, session_name = "", cwd = "/tmp", tab_title = "t" },
})
-- Missing cwd
tiling.update({
    type = "move_pane_to_session",
    data = { pty_id = 2, session_name = "foo", tab_title = "t" },
})
-- Empty cwd
tiling.update({
    type = "move_pane_to_session",
    data = { pty_id = 2, session_name = "foo", cwd = "", tab_title = "t" },
})
s = t.get_state()
assert(#place_calls == 0, "missing-fields: place_pty_in_session never called")
assert(s.tabs[1].root.type == "split", "missing-fields: source tree unchanged")
assert(save_calls == 0, "missing-fields: no saves fired")

-- === Solo main-tree pane with floating: floating closed on tab drop ===

do
    reset_captures()
    local float_pane = mock_tracked_close_pane(77)
    local tab1 = {
        id = 1,
        root = mock_pane(1),
        last_focused_id = 1,
    }
    tab1.floating = { pane = float_pane, visible = true }
    t.set_state({
        tabs = {
            tab1,
            { id = 2, root = mock_pane(99), last_focused_id = 99 },
        },
        active_tab = 2,
        focused_id = 99,
        next_tab_id = 3,
    })
    tiling.update({
        type = "move_pane_to_session",
        data = {
            pty_id = 1,
            session_name = "bar",
            cwd = "/tmp/bar",
            tab_title = "float-orphan",
        },
    })
    s = t.get_state()
    assert(#s.tabs == 1, "float-orphan: source tab dropped")
    assert(s.tabs[1].root.id == 99, "float-orphan: surviving tab is the sibling")
    assert(float_pane.pty._closed, "float-orphan: floating pane pty closed")
    assert(#place_calls == 1, "float-orphan: place_pty_in_session called")
end

-- === Solo main-tree pane with overlay: overlay closed on tab drop ===

do
    reset_captures()
    local overlay_pane = mock_tracked_close_pane(88)
    local tab1 = {
        id = 1,
        root = mock_pane(2),
        last_focused_id = 2,
    }
    tab1.overlays = { tools = { pane = overlay_pane, visible = true } }
    t.set_state({
        tabs = {
            tab1,
            { id = 2, root = mock_pane(99), last_focused_id = 99 },
        },
        active_tab = 2,
        focused_id = 99,
        next_tab_id = 3,
    })
    tiling.update({
        type = "move_pane_to_session",
        data = {
            pty_id = 2,
            session_name = "baz",
            cwd = "/tmp/baz",
            tab_title = "overlay-orphan",
        },
    })
    s = t.get_state()
    assert(#s.tabs == 1, "overlay-orphan: source tab dropped")
    assert(s.tabs[1].root.id == 99, "overlay-orphan: surviving tab is the sibling")
    assert(overlay_pane.pty._closed, "overlay-orphan: overlay pane pty closed")
    assert(#place_calls == 1, "overlay-orphan: place_pty_in_session called")
end

-- === Return value: widened tagged table `{ ok, reason }` on happy path ===
-- fn-111: return shape widened from bool to `{ ok = <bool>, reason = <token> }`.
-- Existing `if ret then ... end` truthy checks still work (non-nil tables
-- are truthy). Reason-aware callers read `ret.ok` / `ret.reason`.

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
local happy_ret = tiling.update({
    type = "move_pane_to_session",
    data = {
        pty_id = 2,
        session_name = "foo",
        cwd = "/home/user/code/foo",
        tab_title = "my-claude",
    },
})
assert(type(happy_ret) == "table", "return-happy: returns a table (widened shape)")
assert(happy_ret.ok == true, "return-happy: ok=true on successful move")
assert(happy_ret.reason == "moved", "return-happy: reason=moved, got " .. tostring(happy_ret.reason))

-- === Return value: `{ ok = false, reason = "absent_from_viewer" }` when pane missing ===

reset_captures()
t.set_state({
    tabs = {
        { id = 1, root = mock_pane(1), last_focused_id = 1 },
        { id = 2, root = mock_pane(2), last_focused_id = 2 },
    },
    active_tab = 1,
    focused_id = 1,
    next_tab_id = 3,
})
local missing_ret = tiling.update({
    type = "move_pane_to_session",
    data = {
        pty_id = 999, -- not in state.tabs
        session_name = "foo",
        cwd = "/tmp/foo",
        tab_title = "ghost",
    },
})
assert(type(missing_ret) == "table", "return-missing: returns a table")
assert(missing_ret.ok == false, "return-missing: ok=false when pane absent")
assert(missing_ret.reason == "absent_from_viewer",
    "return-missing: reason=absent_from_viewer, got " .. tostring(missing_ret.reason))
assert(#place_calls == 0, "return-missing: place_pty_in_session NOT called")
assert(save_calls == 0, "return-missing: prise.save NOT called")

-- === Return value: `{ ok = true, reason = "moved" }` on solo-only (post-fn-111) ===
-- fn-111 dropped the solo-pane-in-only-tab refusal. The move now succeeds
-- and the source session is closed as post-move cleanup.

reset_captures()
session_name_return = "alpha"
list_sessions_return = { "alpha", "bravo" }
t.set_state({
    tabs = {
        { id = 1, root = mock_pane(1), last_focused_id = 1 },
    },
    active_tab = 1,
    focused_id = 1,
    next_tab_id = 2,
})
local solo_ret = tiling.update({
    type = "move_pane_to_session",
    data = {
        pty_id = 1,
        session_name = "bravo",
        cwd = "/tmp",
        tab_title = "t",
    },
})
assert(type(solo_ret) == "table", "return-solo: returns a table")
assert(solo_ret.ok == true, "return-solo: ok=true (no more pre-flight refusal)")
assert(solo_ret.reason == "moved", "return-solo: reason=moved, got " .. tostring(solo_ret.reason))

-- === Return value: `{ ok = false, reason = "bad_args" }` on bad args ===

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
local bad_pty_ret = tiling.update({
    type = "move_pane_to_session",
    ---@diagnostic disable-next-line: assign-type-mismatch
    data = { pty_id = "not-a-number", session_name = "foo", cwd = "/tmp", tab_title = "t" },
})
assert(type(bad_pty_ret) == "table", "return-bad-pty: returns a table")
assert(bad_pty_ret.ok == false, "return-bad-pty: ok=false on non-number pty_id")
assert(bad_pty_ret.reason == "bad_args", "return-bad-pty: reason=bad_args")

local bad_session_ret = tiling.update({
    type = "move_pane_to_session",
    data = { pty_id = 2, session_name = "", cwd = "/tmp", tab_title = "t" },
})
assert(type(bad_session_ret) == "table", "return-bad-session: returns a table")
assert(bad_session_ret.ok == false, "return-bad-session: ok=false on empty session_name")
assert(bad_session_ret.reason == "bad_args", "return-bad-session: reason=bad_args")

local bad_cwd_ret = tiling.update({
    type = "move_pane_to_session",
    data = { pty_id = 2, session_name = "foo", cwd = "", tab_title = "t" },
})
assert(type(bad_cwd_ret) == "table", "return-bad-cwd: returns a table")
assert(bad_cwd_ret.ok == false, "return-bad-cwd: ok=false on empty cwd")
assert(bad_cwd_ret.reason == "bad_args", "return-bad-cwd: reason=bad_args")

-- === Return value: `{ ok = false, reason = "source_solo_destination_unreachable" }` ===
-- fn-111 new reason token: solo-source moved out, destination place_pty failed.
-- Source is already drained + closed by the time place returns false; the
-- distinct reason lets the caller skip DB re-key / viewer-switch effects that
-- would land on a non-existent tab.

reset_captures()
session_name_return = "alpha"
list_sessions_return = { "alpha", "bravo" }
place_return = false
t.set_state({
    tabs = {
        { id = 1, root = mock_pane(1), last_focused_id = 1 },
    },
    active_tab = 1,
    focused_id = 1,
    next_tab_id = 2,
})
local solo_unreachable_ret = tiling.update({
    type = "move_pane_to_session",
    data = {
        pty_id = 1,
        session_name = "bravo",
        cwd = "/tmp",
        tab_title = "t",
    },
})
assert(type(solo_unreachable_ret) == "table", "solo-unreachable: returns a table")
assert(solo_unreachable_ret.ok == false,
    "solo-unreachable: ok=false when destination place fails on a drained source")
assert(solo_unreachable_ret.reason == "source_solo_destination_unreachable",
    "solo-unreachable: reason=source_solo_destination_unreachable, got " .. tostring(solo_unreachable_ret.reason))
assert(#delete_calls == 1, "solo-unreachable: source session still closed (post-move cleanup fired)")
-- place_pty_in_session still invoked + warned once; close_session did not warn
assert(#warn_calls == 1, "solo-unreachable: exactly one warning logged (the place failure), got " .. tostring(#warn_calls))

-- === prise.close_session: refuse non-empty current session ===
-- The primitive must not drain an active session — the caller is
-- responsible for draining tabs first. A non-empty current session close
-- returns false and logs a WARN with the tab count.

reset_captures()
session_name_return = "alpha"
t.set_state({
    tabs = {
        { id = 1, root = mock_pane(1), last_focused_id = 1 },
        { id = 2, root = mock_pane(2), last_focused_id = 2 },
    },
    active_tab = 1,
    focused_id = 1,
    next_tab_id = 3,
})
local close_nonempty_ret = mock_prise.close_session("alpha")
assert(close_nonempty_ret == false, "close_nonempty: refuses a non-empty current session")
assert(#delete_calls == 0, "close_nonempty: delete_session NOT called")
assert(save_calls == 0, "close_nonempty: prise.save NOT called")
assert(#warn_calls == 1, "close_nonempty: one WARN logged, got " .. tostring(#warn_calls))
assert(warn_calls[1]:find("close_session", 1, true), "close_nonempty: warn mentions close_session")
assert(warn_calls[1]:find("tab_count=2", 1, true), "close_nonempty: warn reports tab count")

-- === prise.close_session: close an empty current session + re-anchor viewer ===

reset_captures()
session_name_return = "alpha"
list_sessions_return = { "alpha", "bravo" }
t.set_state({
    tabs = {},
    active_tab = 1,
    focused_id = nil,
    next_tab_id = 1,
})
local close_empty_ret = mock_prise.close_session("alpha")
assert(close_empty_ret == true, "close_empty: returns true on empty session close")
assert(#delete_calls == 1, "close_empty: delete_session called exactly once")
assert(delete_calls[1] == "alpha", "close_empty: delete targets named session")
assert(#switch_calls == 1, "close_empty: viewer re-anchored before delete")
assert(switch_calls[1] == "bravo", "close_empty: viewer re-anchors to remaining session")
assert(save_calls == 1, "close_empty: prise.save flushed after close")
assert(#warn_calls == 0, "close_empty: no warnings on happy path")

-- === prise.close_session: last-session edge — zero-sessions transient OK ===
-- Closing the only session leaves the viewer momentarily attached to nothing.
-- Prise tolerates this; the primitive doesn't switch (no fallback available).

reset_captures()
session_name_return = "alpha"
list_sessions_return = { "alpha" } -- only one session exists
t.set_state({
    tabs = {},
    active_tab = 1,
    focused_id = nil,
    next_tab_id = 1,
})
local close_last_ret = mock_prise.close_session("alpha")
assert(close_last_ret == true, "close_last: returns true when closing the last session")
assert(#delete_calls == 1, "close_last: delete_session still fires")
assert(#switch_calls == 0, "close_last: viewer NOT switched (no fallback available)")
assert(save_calls == 1, "close_last: prise.save flushed")

-- === prise.close_session: off-viewer session — delete proceeds ===
-- When the named session isn't the viewer's current session, emptiness can't
-- be verified from viewer state. The primitive delegates to delete_session
-- (idempotent on ENOENT) without a refuse-non-empty gate. Callers that need
-- that gate for off-viewer sessions pre-check before invoking.

reset_captures()
session_name_return = "alpha"
t.set_state({
    tabs = {
        { id = 1, root = mock_pane(1), last_focused_id = 1 },
    },
    active_tab = 1,
    focused_id = 1,
    next_tab_id = 2,
})
local close_offviewer_ret = mock_prise.close_session("bravo")
assert(close_offviewer_ret == true, "close_offviewer: delete proceeds for non-current session")
assert(#delete_calls == 1, "close_offviewer: delete_session called once")
assert(delete_calls[1] == "bravo", "close_offviewer: delete targets named session")
assert(#switch_calls == 0, "close_offviewer: no viewer switch (not current)")
assert(save_calls == 1, "close_offviewer: prise.save flushed")

-- === prise.close_session: bad args — empty or non-string ===

reset_captures()
local close_empty_name_ret = mock_prise.close_session("")
assert(close_empty_name_ret == false, "close_bad: empty session_name refused")
assert(#delete_calls == 0, "close_bad: delete NOT called on bad args")

---@diagnostic disable-next-line: param-type-mismatch
local close_nil_ret = mock_prise.close_session(nil)
assert(close_nil_ret == false, "close_bad: nil session_name refused")
assert(#delete_calls == 0, "close_bad: delete NOT called on nil")
