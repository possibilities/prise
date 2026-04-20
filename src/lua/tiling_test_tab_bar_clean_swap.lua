--- Tests for M.set_tab_shell — the nil-root, pty-free derivation path used
--- at session-switch time so the tab bar can swap old->new in a single frame.
---
--- Contract (see tiling.lua:M.set_tab_shell):
---   1. Populates state.tabs with shells (id, title, last_focused_id, root = nil)
---   2. Sets state.active_tab, state.next_tab_id, state.tab_bar_scroll_offset
---   3. Does NOT call deserialize_node and never binds pty refs
---   4. A follow-up set_state(plan_json, live_lookup) rebinds live ptys
local helpers = require("test_helpers")
local mock_pane = helpers.mock_pane
local mock_pty = helpers.mock_pty
helpers.setup_prise_mock()

local tiling = require("tiling")
local t = tiling._test

-- === Case 1: derivation — set_tab_shell paints tab metadata, every root is nil ===

-- JSON shape mirrors what get_state produces: pane nodes carry `pty_id`
-- (for lookup at rebind time), `id` is the pane id.
local plan_json = {
    tabs = {
        { id = 1, title = "shell", last_focused_id = 11, root = { type = "pane", id = 11, pty_id = 11 } },
        { id = 2, title = "logs", last_focused_id = 22, root = { type = "pane", id = 22, pty_id = 22 } },
    },
    active_tab = 2,
    next_tab_id = 3,
}

tiling.set_tab_shell(plan_json)
local state = t.get_state()

assert(#state.tabs == 2, "set_tab_shell: two tabs created")
assert(state.tabs[1].id == 1, "set_tab_shell: tab 1 id")
assert(state.tabs[1].title == "shell", "set_tab_shell: tab 1 title")
assert(state.tabs[1].last_focused_id == 11, "set_tab_shell: tab 1 last_focused_id")
assert(state.tabs[1].root == nil, "set_tab_shell: tab 1 root is nil (no pty binding)")
assert(state.tabs[2].id == 2, "set_tab_shell: tab 2 id")
assert(state.tabs[2].title == "logs", "set_tab_shell: tab 2 title")
assert(state.tabs[2].root == nil, "set_tab_shell: tab 2 root is nil (no pty binding)")
assert(state.active_tab == 2, "set_tab_shell: active_tab set from JSON")
assert(state.next_tab_id == 3, "set_tab_shell: next_tab_id restored from JSON")
assert(state.tab_bar_scroll_offset == 0, "set_tab_shell: tab_bar_scroll_offset defaults to 0")

-- === Case 2: completion-time rebind — calling set_state after set_tab_shell
--     populates pty refs without changing tab count or titles ===

local live_ptys = {
    [11] = mock_pty(11),
    [22] = mock_pty(22),
}
local function live_lookup(id)
    return live_ptys[id]
end

-- Same JSON shape as plan_json; represents the plan replayed at completion time.
tiling.set_state({
    tabs = {
        { id = 1, title = "shell", last_focused_id = 11, root = { type = "pane", id = 11, pty_id = 11 } },
        { id = 2, title = "logs", last_focused_id = 22, root = { type = "pane", id = 22, pty_id = 22 } },
    },
    active_tab = 2,
    next_tab_id = 3,
}, live_lookup)

state = t.get_state()
assert(#state.tabs == 2, "rebind: tab count unchanged")
assert(state.tabs[1].title == "shell", "rebind: tab 1 title preserved")
assert(state.tabs[2].title == "logs", "rebind: tab 2 title preserved")
assert(state.tabs[1].root ~= nil, "rebind: tab 1 root populated")
assert(state.tabs[1].root.type == "pane", "rebind: tab 1 root is pane node")
assert(state.tabs[1].root.pty ~= nil, "rebind: tab 1 pty bound")
assert(state.tabs[1].root.pty:id() == 11, "rebind: tab 1 pty id matches")
assert(state.tabs[2].root ~= nil, "rebind: tab 2 root populated")
assert(state.tabs[2].root.pty:id() == 22, "rebind: tab 2 pty id matches")
assert(state.active_tab == 2, "rebind: active_tab preserved")

-- === Case 3: zero-tab edge case — empty tabs array does not crash ===

tiling.set_tab_shell({
    tabs = {},
    active_tab = 1,
    next_tab_id = 1,
})
state = t.get_state()
assert(#state.tabs == 0, "zero tabs: tabs array is empty")
assert(state.tab_bar_scroll_offset == 0, "zero tabs: scroll offset reset to 0")

-- Also exercise the nil-saved branch (no JSON at all): should clear state,
-- not crash, and not populate tabs.
tiling.set_tab_shell(nil)
state = t.get_state()
assert(#state.tabs == 0, "nil saved: tabs array is empty")

print("tab bar clean swap: all cases passed")
