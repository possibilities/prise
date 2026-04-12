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
        return "test"
    end,
    attach = function() end,
    switch_session = function()
        return true
    end,
    rename_session = function() end,
    create_session = function() end,
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
    place_calls = {}
    place_return = true
    warn_calls = {}
    save_calls = 0
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

-- === Solo pane in the only tab: refuse (would empty session) ===

reset_captures()
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
        session_name = "foo",
        cwd = "/tmp",
        tab_title = "t",
    },
})
s = t.get_state()
assert(#s.tabs == 1, "solo-only: tab count unchanged")
assert(s.tabs[1].root.id == 1, "solo-only: pane still present")
assert(#place_calls == 0, "solo-only: place_pty_in_session NOT called")
assert(save_calls == 0, "solo-only: prise.save NOT called (pure no-op)")

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
