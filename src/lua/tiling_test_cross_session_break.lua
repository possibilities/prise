-- Regression test for B5 cross-session break (fn-45-fix-b5-cross-session-break).
-- Pins the matrix post-conditions: when the viewer is on an unrelated session
-- and a break fires for a pane in the source session, the new tab MUST land
-- in the SOURCE session's saved JSON (not in the viewer's session) and the
-- viewer's state.tabs / active_tab MUST be untouched.
--
-- This file is a focused B5-only test. Broader cross-session break scenarios
-- (happy path with focus follow-on, place-fail orphan, missing cwd, etc.) live
-- in tiling_test_break_pane_to_session.lua. Both files mock prise inline per
-- the 2026-04-11 test_helpers phase-out policy.
--
-- Pre-fix behavior (fn-14, regressed by fn-45 round-5 verify): the cross-session
-- arm called table.insert(state.tabs, ...) and prise.save() on the VIEWER's
-- session. Charlie ended up with a phantom new tab; alpha was untouched.
--
-- Post-fix behavior: cross-session arm calls
-- prise.remove_pty_from_session(source, pty) followed by
-- prise.place_pty_in_session(source, pty, cwd, tab_title). Both target the
-- source session. Viewer's state.tabs is not mutated. The
-- session_file_changed coherence broadcast handles any other client attached
-- to source.

---@param id number
---@return table
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

---@param id number
---@return table
local function mock_pane(id)
    return { type = "pane", id = id, pty = mock_pty(id) }
end

-- Capture buffers for the mocked prise binding calls. reset_captures() blanks
-- them between scenarios so each B5 variant only sees its own effects.
local remove_calls = {}
local remove_return = true
local place_calls = {}
local place_return = true
local warn_calls = {}
local info_calls = {}
local save_calls = 0
local request_frame_calls = 0
local current_session = "charlie" -- B5 default: viewer is on charlie

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
    request_frame = function()
        request_frame_calls = request_frame_calls + 1
    end,
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
        info = function(msg)
            table.insert(info_calls, msg)
        end,
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

local function reset_captures()
    remove_calls = {}
    remove_return = true
    place_calls = {}
    place_return = true
    warn_calls = {}
    info_calls = {}
    save_calls = 0
    request_frame_calls = 0
    current_session = "charlie"
end

-- ========================================================================
-- B5 — Break, viewer on unrelated session
-- ========================================================================
-- Per ~/docs/prise-manage-pane-scenario-matrix-2026-04-17.md:
--   Preconditions: alpha exists with C_old; charlie exists; viewer is on
--   charlie. C_new arrives in alpha's collision tab.
--   Expected: C_new evicted into a fresh tab in alpha at
--   normalize(active_tab)+1; alpha.active_tab unchanged at 1; charlie
--   untouched; user still in charlie.
--
-- The Lua-side pinning here covers: (1) place targets alpha (source), (2)
-- viewer's state.tabs is untouched (charlie not given a phantom tab),
-- (3) viewer's prise.save() is not called. The on-disk position assertion
-- (normalize(active_tab)+1) lives downstream of the Lua mock — server-side
-- appendTabToSessionFile owns it.

-- === B5 canonical: 1-tab viewer (charlie) with c-shell only ===

reset_captures()
current_session = "charlie"
-- Viewer (charlie) has 1 tab containing the c-shell pty 1 — exactly the
-- shape produced by `prisectl start-pty charlie cz` per the brief.
t.set_state({
    tabs = {
        { id = 1, root = mock_pane(1), last_focused_id = 1 },
    },
    active_tab = 1,
    focused_id = 1,
    next_tab_id = 2,
})

-- pty 2 (C_new) lives in alpha's collision tab. Break fires while viewer is
-- on charlie. arthack init.lua plumbs source_session=alpha, cwd=alpha-path.
local b5_ret = tiling.update({
    type = "break_pane",
    data = {
        pty_id = 2,
        source_session = "alpha",
        cwd = "/Users/mike/code/alpha",
        focus = false,
    },
})

assert(b5_ret == true, "B5: cross-session break returns true")

-- Source-targeting: remove + place both go to alpha.
assert(#remove_calls == 1, "B5: remove called exactly once")
assert(remove_calls[1].session_name == "alpha", "B5: remove targets source 'alpha'")
assert(remove_calls[1].pty_id == 2, "B5: remove gets correct pty_id (2)")
assert(#place_calls == 1, "B5: place called exactly once")
assert(place_calls[1].session_name == "alpha", "B5: place targets source 'alpha' (NOT viewer 'charlie')")
assert(place_calls[1].pty_id == 2, "B5: place gets correct pty_id (2)")
assert(place_calls[1].cwd == "/Users/mike/code/alpha", "B5: place gets cwd from event data")

-- Viewer isolation: charlie's state.tabs is untouched.
local viewer_state = t.get_state()
assert(#viewer_state.tabs == 1, "B5: charlie tab count unchanged (1) — no phantom tab in viewer")
assert(viewer_state.tabs[1].id == 1, "B5: charlie's tab 1 identity preserved")
assert(viewer_state.tabs[1].root.id == 1, "B5: charlie's c-shell pty 1 still present")
assert(viewer_state.active_tab == 1, "B5: charlie active_tab unchanged (1)")
assert(viewer_state.focused_id == 1, "B5: charlie focused_id unchanged (c-shell)")

-- No viewer-side autosave or frame request — the viewer's session has
-- nothing to save and nothing visual changed. The session_file_changed
-- coherence broadcast (server-side) handles any other client attached to
-- alpha.
assert(save_calls == 0, "B5: viewer's prise.save() NOT called (matrix-wins: no viewer mutation)")
assert(request_frame_calls == 0, "B5: viewer's prise.request_frame() NOT called")

-- Instrumentation present: entry / pre-remove / post-remove / done lines
-- should all have fired. Spec: "Instrumentation added to cross-session
-- break_pane branch ... Left in place post-fix — not removed".
local function any_info_line_matches(needle)
    for _, msg in ipairs(info_calls) do
        if msg:find(needle, 1, true) then
            return true
        end
    end
    return false
end
assert(any_info_line_matches("cross-session entry"), "B5: instrumentation present: entry line")
assert(any_info_line_matches("cross-session pre-remove"), "B5: instrumentation present: pre-remove line")
assert(any_info_line_matches("cross-session post-remove"), "B5: instrumentation present: post-remove line")
assert(any_info_line_matches("cross-session done"), "B5: instrumentation present: done line")

-- No warns on the happy path.
assert(#warn_calls == 0, "B5: no warns on happy path")

-- === B5 with multi-tab viewer (charlie has 3 tabs) ===
-- Confirms viewer isolation regardless of viewer's tab count / active_tab.

reset_captures()
current_session = "charlie"
t.set_state({
    tabs = {
        { id = 1, root = mock_pane(10), last_focused_id = 10 },
        { id = 2, root = mock_pane(11), last_focused_id = 11 },
        { id = 3, root = mock_pane(12), last_focused_id = 12 },
    },
    active_tab = 2,
    focused_id = 11,
    next_tab_id = 4,
})
local b5_multi_ret = tiling.update({
    type = "break_pane",
    data = {
        pty_id = 99,
        source_session = "alpha",
        cwd = "/Users/mike/code/alpha",
        focus = false,
    },
})
assert(b5_multi_ret == true, "B5 multi-tab viewer: returns true")
assert(place_calls[1].session_name == "alpha", "B5 multi-tab viewer: place targets source 'alpha'")
local viewer_multi = t.get_state()
assert(#viewer_multi.tabs == 3, "B5 multi-tab viewer: tab count unchanged (3)")
assert(viewer_multi.active_tab == 2, "B5 multi-tab viewer: active_tab unchanged (2)")
assert(viewer_multi.tabs[1].id == 1, "B5 multi-tab viewer: tab 1 unchanged")
assert(viewer_multi.tabs[2].id == 2, "B5 multi-tab viewer: tab 2 unchanged")
assert(viewer_multi.tabs[3].id == 3, "B5 multi-tab viewer: tab 3 unchanged (NOT pushed by phantom insert)")

-- === B5 with empty viewer (just attached, no tabs yet) ===
-- Pre-fix this scenario inserted into the viewer at index 1
-- (#state.tabs == 0 → 1 placement degenerate). Post-fix the viewer stays
-- empty; place still targets source.

reset_captures()
current_session = "charlie"
t.set_state({
    tabs = {},
    active_tab = 1,
    focused_id = nil,
    next_tab_id = 1,
})
local b5_empty_ret = tiling.update({
    type = "break_pane",
    data = {
        pty_id = 200,
        source_session = "alpha",
        cwd = "/Users/mike/code/alpha",
        focus = false,
    },
})
assert(b5_empty_ret == true, "B5 empty viewer: returns true")
assert(place_calls[1].session_name == "alpha", "B5 empty viewer: place targets source 'alpha'")
local viewer_empty = t.get_state()
assert(#viewer_empty.tabs == 0, "B5 empty viewer: viewer tabs remain empty")
