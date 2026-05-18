local helpers = require("test_helpers")
local mock_pane = helpers.mock_pane
local mock_pty = helpers.mock_pty
local mock_tab = helpers.mock_tab
helpers.setup_prise_mock()

local tiling = require("tiling")
local t = tiling._test

local state
for i = 1, 256 do
    local name, val = debug.getupvalue(tiling.update, i)
    if not name then
        break
    end
    if name == "state" then
        state = val
        break
    end
end
assert(state, "could not find state upvalue")

-- === spawn placement ===

-- Test: pty_spawned with title queues pending rename (and creates new tab since tab is nil)
state.pending_title_renames = {}
state.pending_spawns = {}
tiling.update({ type = "pty_spawned", data = { id = 5, title = "editor" } })
assert(state.pending_title_renames[5] == "editor", "pty_spawned: title queues pending rename")
assert(
    state.pending_spawns[5] ~= nil and state.pending_spawns[5].new_tab == true,
    "pty_spawned: nil tab creates new tab"
)

-- Test: pty_spawned with tab="new" sets pending new_tab
state.pending_spawns = {}
tiling.update({ type = "pty_spawned", data = { id = 6, tab = "new" } })
assert(state.pending_spawns[6] ~= nil and state.pending_spawns[6].new_tab == true, "pty_spawned: tab=new sets new_tab")

-- Test: pty_spawned without placement fields is no-op
state.pending_spawns = {}
state.pending_title_renames = {}
tiling.update({ type = "pty_spawned", data = { id = 7 } })
assert(state.pending_spawns[7] == nil, "pty_spawned: no placement fields, no pending spawn")
assert(state.pending_title_renames[7] == nil, "pty_spawned: no placement fields, no pending rename")

-- === find_tab_by_title ===

-- Test: find_tab_by_title returns correct index and tab when found
state.tabs = {
    { id = 1, root = mock_pane(1), title = "alpha" },
    { id = 2, root = mock_pane(2), title = "beta" },
    { id = 3, root = mock_pane(3), title = "gamma" },
}
local idx, found_tab = t.find_tab_by_title("beta")
assert(idx == 2, "find_tab_by_title: correct index")
assert(found_tab ~= nil and found_tab.title == "beta", "find_tab_by_title: correct tab")

-- Test: find_tab_by_title returns nil when not found
idx = t.find_tab_by_title("nonexistent")
assert(idx == nil, "find_tab_by_title: nil when not found")

-- === pty_spawned with named tab ===

-- Test: pty_spawned with known tab name registers no-focus spawn but does NOT
-- switch to the tab unless data.focus == true. Programmatic spawns must not
-- steal focus from whatever tab the human is currently in.
state.tabs = {
    { id = 1, root = mock_pane(1), title = "code", last_focused_id = 1 },
    { id = 2, root = mock_pane(2), title = "logs", last_focused_id = 2 },
}
state.active_tab = 1
state.pending_spawns = {}
state.pending_title_renames = {}
tiling.update({ type = "pty_spawned", data = { id = 20, tab = "logs" } })
assert(state.active_tab == 1, "pty_spawned: known tab name does NOT switch active tab without focus=true")
assert(
    state.pending_spawns[20] ~= nil and state.pending_spawns[20].new_tab == false,
    "pty_spawned: known tab name still records pending spawn with new_tab=false"
)
assert(state.pending_spawns[20].no_focus == true, "pty_spawned: unset focus yields no_focus=true on pending spawn")

-- Test: pty_spawned with focus=true switches to the matched tab
state.active_tab = 1
state.pending_spawns = {}
tiling.update({ type = "pty_spawned", data = { id = 24, tab = "logs", focus = true } })
assert(state.active_tab == 2, "pty_spawned: focus=true switches to matched named tab")
assert(
    state.pending_spawns[24] ~= nil and state.pending_spawns[24].no_focus == false,
    "pty_spawned: focus=true yields no_focus=false on pending spawn"
)

-- Test: pty_spawned with unknown tab name creates new tab
state.tabs = {
    { id = 1, root = mock_pane(1), title = "code", last_focused_id = 1 },
}
state.active_tab = 1
state.pending_spawns = {}
tiling.update({ type = "pty_spawned", data = { id = 21, tab = "unknown" } })
assert(
    state.pending_spawns[21] ~= nil and state.pending_spawns[21].new_tab == true,
    "pty_spawned: unknown tab name creates new tab"
)

-- === cross-session placement ===

-- Test: pty_spawned with different session calls place_pty_in_session, NOT attach
local mock_prise = package.loaded["prise"]
local place_calls = {}
local attach_calls = {}
---@diagnostic disable: duplicate-set-field
mock_prise.place_pty_in_session = function(session, pty_id, cwd, title)
    table.insert(place_calls, { session = session, pty_id = pty_id, cwd = cwd, title = title })
    return true
end
mock_prise.attach = function(id)
    table.insert(attach_calls, id)
end
---@diagnostic enable: duplicate-set-field

state.tabs = { { id = 1, root = mock_pane(1), title = "old", last_focused_id = 1 } }
state.active_tab = 1
state.pending_spawns = {}
state.pending_title_renames = {}
place_calls = {}
attach_calls = {}

tiling.update({
    type = "pty_spawned",
    data = { id = 30, session = "other", cwd = "/tmp", title = "worker", tab = "new" },
})
assert(#place_calls == 1, "cross-session: place_pty_in_session called")
assert(place_calls[1].session == "other", "cross-session: correct session name")
assert(place_calls[1].pty_id == 30, "cross-session: correct pty_id")
assert(place_calls[1].cwd == "/tmp", "cross-session: correct cwd")
assert(place_calls[1].title == "worker", "cross-session: correct title")
assert(#attach_calls == 0, "cross-session: attach NOT called")
assert(state.pending_spawns[30] == nil, "cross-session: no pending spawn")

-- Test: pty_spawned with same session uses attach (not place_pty_in_session)
place_calls = {}
attach_calls = {}
state.pending_spawns = {}
state.pending_title_renames = {}

tiling.update({
    type = "pty_spawned",
    data = { id = 31, session = "test", cwd = "/home", tab = "new", title = "local" },
})
assert(#place_calls == 0, "same-session: place_pty_in_session NOT called")
assert(#attach_calls == 1, "same-session: attach called")
assert(attach_calls[1] == 31, "same-session: correct pty attached")
assert(state.pending_spawns[31] ~= nil and state.pending_spawns[31].new_tab == true, "same-session: new_tab set")
assert(state.pending_title_renames[31] == "local", "same-session: title rename queued")

-- Test: pty_spawned with same session but no other placement fields still attaches
place_calls = {}
attach_calls = {}
state.pending_spawns = {}
state.pending_title_renames = {}

tiling.update({
    type = "pty_spawned",
    data = { id = 33, session = "test" },
})
assert(#place_calls == 0, "same-session-only: place_pty_in_session NOT called")
assert(#attach_calls == 1, "same-session-only: attach called")
assert(attach_calls[1] == 33, "same-session-only: correct pty attached")
assert(
    state.pending_spawns[33] ~= nil and state.pending_spawns[33].new_tab == true,
    "same-session-only: defaults to new tab"
)

-- Test: pty_spawned with no session field uses attach
place_calls = {}
attach_calls = {}
state.pending_spawns = {}
state.pending_title_renames = {}

tiling.update({ type = "pty_spawned", data = { id = 32, tab = "new", title = "nosess" } })
assert(#place_calls == 0, "no-session: place_pty_in_session NOT called")
assert(#attach_calls == 1, "no-session: attach called")
assert(attach_calls[1] == 32, "no-session: correct pty attached")

-- Restore mock defaults
---@diagnostic disable: duplicate-set-field
mock_prise.place_pty_in_session = function()
    return true
end
mock_prise.attach = function() end
---@diagnostic enable: duplicate-set-field

-- Test: pending title applied on pty_attach
state.tabs = { mock_tab(mock_pane(1)) }
state.active_tab = 1
state.focused_id = 1
state.pending_title_renames = { [10] = "my-title" }
state.pending_spawns = {}
state.pending_split = nil
state.pending_layout = nil
state.floating = { pending = false, visible = false, width = 100, height = 30 }
tiling.update({ type = "pty_attach", data = { pty = mock_pty(10) } })
assert(state.tabs[1].title == "my-title", "pty_attach: pending title applied to tab")
assert(state.pending_title_renames[10] == nil, "pty_attach: pending rename cleared")

-- === focus control ===

-- Test: programmatic spawn (placement fields, no focus) does not steal focus
state.tabs = { mock_tab(mock_pane(1)) }
state.active_tab = 1
state.focused_id = 1
state.pending_spawns = {}
state.pending_split = nil
state.pending_layout = nil
state.pending_title_renames = {}
state.floating = { pending = false, visible = false, width = 100, height = 30 }
tiling.update({ type = "pty_spawned", data = { id = 40, tab = "new", title = "bg" } })
assert(
    state.pending_spawns[40] ~= nil and state.pending_spawns[40].no_focus == true,
    "pty_spawned: placement without focus sets no_focus"
)
assert(state.pending_spawns[40].new_tab == true, "pty_spawned: new_tab set for attach")
-- Simulate the attach
tiling.update({ type = "pty_attach", data = { pty = mock_pty(40) } })
assert(state.focused_id == 1, "pty_attach: focus stays on original pane when no_focus")
assert(state.active_tab == 1, "pty_attach: active_tab stays on original tab when no_focus")
assert(state.pending_spawns[40] == nil, "pty_attach: pending spawn cleared after use")

-- Test: programmatic spawn with focus=true DOES steal focus
state.tabs = { mock_tab(mock_pane(1)) }
state.active_tab = 1
state.focused_id = 1
state.pending_spawns = {}
state.pending_split = nil
state.pending_layout = nil
state.pending_title_renames = {}
state.floating = { pending = false, visible = false, width = 100, height = 30 }
tiling.update({ type = "pty_spawned", data = { id = 41, tab = "new", title = "fg", focus = true } })
assert(
    state.pending_spawns[41] ~= nil and state.pending_spawns[41].no_focus == false,
    "pty_spawned: focus=true does not set no_focus"
)
-- Simulate the attach
tiling.update({ type = "pty_attach", data = { pty = mock_pty(41) } })
assert(state.focused_id == 41, "pty_attach: focus moves to new pane when focus=true")

-- Test: human-initiated spawn (no placement fields) always gets focus
state.tabs = { mock_tab(mock_pane(1)) }
state.active_tab = 1
state.focused_id = 1
state.pending_spawns = {}
state.pending_split = nil
state.pending_layout = nil
state.pending_title_renames = {}
state.floating = { pending = false, visible = false, width = 100, height = 30 }
-- No placement fields — human-initiated path, no pty_spawned handler runs
tiling.update({ type = "pty_attach", data = { pty = mock_pty(42) } })
assert(state.focused_id == 42, "pty_attach: human-initiated spawn gets focus")

-- === concurrent spawn race ===

-- Test: two pty_spawned events before either pty_attach — both flags preserved
state.tabs = { mock_tab(mock_pane(1)) }
state.active_tab = 1
state.focused_id = 1
state.pending_spawns = {}
state.pending_split = nil
state.pending_layout = nil
state.pending_title_renames = {}
state.floating = { pending = false, visible = false, width = 100, height = 30 }

tiling.update({ type = "pty_spawned", data = { id = 50, tab = "new", title = "first" } })
tiling.update({ type = "pty_spawned", data = { id = 51, tab = "new", title = "second", focus = true } })

-- Both spawns should have independent entries
assert(state.pending_spawns[50] ~= nil, "concurrent: first spawn opts exist")
assert(state.pending_spawns[50].new_tab == true, "concurrent: first spawn new_tab")
assert(state.pending_spawns[50].no_focus == true, "concurrent: first spawn no_focus")
assert(state.pending_spawns[51] ~= nil, "concurrent: second spawn opts exist")
assert(state.pending_spawns[51].new_tab == true, "concurrent: second spawn new_tab")
assert(state.pending_spawns[51].no_focus == false, "concurrent: second spawn has focus")

-- Attach first — should not clobber second
tiling.update({ type = "pty_attach", data = { pty = mock_pty(50) } })
assert(state.pending_spawns[50] == nil, "concurrent: first spawn cleared after attach")
assert(state.pending_spawns[51] ~= nil, "concurrent: second spawn still pending")
assert(state.focused_id == 1, "concurrent: first attach did not steal focus")

-- Attach second — should get focus
tiling.update({ type = "pty_attach", data = { pty = mock_pty(51) } })
assert(state.pending_spawns[51] == nil, "concurrent: second spawn cleared after attach")
assert(state.focused_id == 51, "concurrent: second attach got focus")
