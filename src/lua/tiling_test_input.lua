local helpers = require("test_helpers")
local mock_tab = helpers.mock_tab
local mock_tracked_pty = helpers.mock_tracked_pty
helpers.setup_prise_mock()

local tiling = require("tiling")

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

-- === send_key_to_focused ===

-- Test: sends key to focused pane
local tracked_pty1 = mock_tracked_pty(1)
local key_pane = { type = "pane", id = 1, pty = tracked_pty1 }
state.tabs = { mock_tab(key_pane) }
state.active_tab = 1
state.focused_id = 1
tiling.send_key_to_focused({ key = "a" })
---@diagnostic disable-next-line: undefined-field
assert(#tracked_pty1._calls == 1, "send_key: focused pane received call")
---@diagnostic disable-next-line: undefined-field
assert(tracked_pty1._calls[1].method == "send_key", "send_key: correct method")

-- Helper: build a tab with both legacy tab.floating and tab.overlays
-- shapes pointing at the same pane. This keeps the test self-contained
-- across branches — on feat/plug-system in isolation the runtime only
-- reads tab.floating (tab.overlays is an unread field), and on arthack-
-- prod after feat/overlay-terminals merges the runtime reads tab.overlays
-- via get_visible_overlay_pty. Setting both means one test file exercises
-- both runtime models without depending on mock_tab knowing about overlays.
local function tab_with_floating(tab_id, root, float_pane, visible)
    local entry = { pane = float_pane, visible = visible }
    return {
        id = tab_id,
        root = root,
        last_focused_id = 1,
        floating = entry,
        overlays = { floating = entry },
    }
end

-- Test: sends key to floating pane when visible
local tracked_root = mock_tracked_pty(1)
local tracked_float = mock_tracked_pty(9)
local root_pane = { type = "pane", id = 1, pty = tracked_root }
local float_pane = { type = "pane", id = 9, pty = tracked_float }
state.tabs = { tab_with_floating(1, root_pane, float_pane, true) }
state.active_tab = 1
state.focused_id = 1
tiling.send_key_to_focused({ key = "b" })
---@diagnostic disable-next-line: undefined-field
assert(#tracked_float._calls == 1, "send_key: floating pane received call")
---@diagnostic disable-next-line: undefined-field
assert(#tracked_root._calls == 0, "send_key: root pane did not receive call")

-- Test: sends key to focused when floating hidden
local tracked_root2 = mock_tracked_pty(1)
local tracked_float2 = mock_tracked_pty(9)
local root_pane2 = { type = "pane", id = 1, pty = tracked_root2 }
local float_pane2 = { type = "pane", id = 9, pty = tracked_float2 }
state.tabs = { tab_with_floating(1, root_pane2, float_pane2, false) }
state.active_tab = 1
state.focused_id = 1
tiling.send_key_to_focused({ key = "c" })
---@diagnostic disable-next-line: undefined-field
assert(#tracked_root2._calls == 1, "send_key: root pane received call when floating hidden")
---@diagnostic disable-next-line: undefined-field
assert(#tracked_float2._calls == 0, "send_key: hidden floating pane did not receive call")

-- === send_mouse_to_focused ===

-- Test: sends mouse to focused pane
local mouse_tracked_pty1 = mock_tracked_pty(1)
local mouse_pane = { type = "pane", id = 1, pty = mouse_tracked_pty1 }
state.tabs = { mock_tab(mouse_pane) }
state.active_tab = 1
state.focused_id = 1
tiling.send_mouse_to_focused({ x = 10, y = 5, button = "left", event_type = "press" })
---@diagnostic disable-next-line: undefined-field
assert(#mouse_tracked_pty1._calls == 1, "send_mouse: focused pane received call")
---@diagnostic disable-next-line: undefined-field
assert(mouse_tracked_pty1._calls[1].method == "send_mouse", "send_mouse: correct method")

-- Test: sends mouse to floating pane when visible
local mouse_tracked_root = mock_tracked_pty(1)
local mouse_tracked_float = mock_tracked_pty(9)
local mouse_root_pane = { type = "pane", id = 1, pty = mouse_tracked_root }
local mouse_float_pane = { type = "pane", id = 9, pty = mouse_tracked_float }
state.tabs = { tab_with_floating(1, mouse_root_pane, mouse_float_pane, true) }
state.active_tab = 1
state.focused_id = 1
tiling.send_mouse_to_focused({ x = 1, y = 1, button = "left", event_type = "press" })
---@diagnostic disable-next-line: undefined-field
assert(#mouse_tracked_float._calls == 1, "send_mouse: floating pane received call")
---@diagnostic disable-next-line: undefined-field
assert(#mouse_tracked_root._calls == 0, "send_mouse: root pane did not receive call")

-- Test: sends mouse to focused when floating hidden
local mouse_tracked_root2 = mock_tracked_pty(1)
local mouse_tracked_float2 = mock_tracked_pty(9)
local mouse_root_pane2 = { type = "pane", id = 1, pty = mouse_tracked_root2 }
local mouse_float_pane2 = { type = "pane", id = 9, pty = mouse_tracked_float2 }
state.tabs = { tab_with_floating(1, mouse_root_pane2, mouse_float_pane2, false) }
state.active_tab = 1
state.focused_id = 1
tiling.send_mouse_to_focused({ x = 5, y = 3, button = "right", event_type = "press" })
---@diagnostic disable-next-line: undefined-field
assert(#mouse_tracked_root2._calls == 1, "send_mouse: root pane received call when floating hidden")
---@diagnostic disable-next-line: undefined-field
assert(#mouse_tracked_float2._calls == 0, "send_mouse: hidden floating pane did not receive call")
