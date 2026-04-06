local helpers = require("test_helpers")
local mock_pane = helpers.mock_pane
helpers.setup_prise_mock()

local tiling = require("tiling")
local t = tiling._test

-- === keep_attached ===

local prise_mock = package.loaded["prise"]
local keep_attached_calls = {}

---Set up mocks for a keep_attached test case
---@param sessions string[]? Sessions that list_sessions returns
---@param current string Current session name
---@param keep boolean Config value for keep_attached
---@param fail_sessions string[]? Session names where switch_session returns false
local function setup_keep_attached_test(sessions, current, keep, fail_sessions)
    keep_attached_calls = {}
    local fail_set = {}
    for _, s in ipairs(fail_sessions or {}) do
        fail_set[s] = true
    end
    prise_mock.exit = function()
        table.insert(keep_attached_calls, "exit")
    end
    prise_mock.switch_session = function(name)
        table.insert(keep_attached_calls, "switch:" .. name)
        return not fail_set[name]
    end
    prise_mock.list_sessions = function()
        return sessions
    end
    prise_mock.get_session_name = function()
        return current
    end
    tiling.setup({ keep_attached = keep })
    t.set_state({
        tabs = { { id = 1, root = mock_pane(1), last_focused_id = 1 } },
        active_tab = 1,
        focused_id = 1,
    })
end

-- Test: keep_attached=true switches to another session when last pane exits
setup_keep_attached_test({ "alpha", "test", "beta" }, "test", true)
tiling.update({ type = "pty_exited", data = { id = 1 } })
assert(#keep_attached_calls == 1, "keep_attached: exactly one action taken")
assert(keep_attached_calls[1] == "switch:alpha", "keep_attached: switches to first other session")

-- Test: keep_attached=true exits when no other sessions exist
setup_keep_attached_test({ "test" }, "test", true)
tiling.update({ type = "pty_exited", data = { id = 1 } })
assert(#keep_attached_calls == 1, "keep_attached no others: exactly one action taken")
assert(keep_attached_calls[1] == "exit", "keep_attached no others: exits when no other sessions")

-- Test: keep_attached=true exits when list_sessions returns nil
setup_keep_attached_test(nil, "test", true)
tiling.update({ type = "pty_exited", data = { id = 1 } })
assert(#keep_attached_calls == 1, "keep_attached nil sessions: exactly one action taken")
assert(keep_attached_calls[1] == "exit", "keep_attached nil sessions: exits when list returns nil")

-- Test: keep_attached=true tries next session when first switch fails
setup_keep_attached_test({ "alpha", "test", "beta" }, "test", true, { "alpha" })
tiling.update({ type = "pty_exited", data = { id = 1 } })
assert(#keep_attached_calls == 2, "keep_attached fallback: tried two sessions")
assert(keep_attached_calls[1] == "switch:alpha", "keep_attached fallback: tried alpha first")
assert(keep_attached_calls[2] == "switch:beta", "keep_attached fallback: fell through to beta")

-- Test: keep_attached=true exits when all switches fail
setup_keep_attached_test({ "alpha", "test", "beta" }, "test", true, { "alpha", "beta" })
tiling.update({ type = "pty_exited", data = { id = 1 } })
assert(#keep_attached_calls == 3, "keep_attached all fail: tried both then exited")
assert(keep_attached_calls[1] == "switch:alpha", "keep_attached all fail: tried alpha")
assert(keep_attached_calls[2] == "switch:beta", "keep_attached all fail: tried beta")
assert(keep_attached_calls[3] == "exit", "keep_attached all fail: exits after all fail")

-- Test: keep_attached=false always exits
setup_keep_attached_test({ "alpha", "test", "beta" }, "test", false)
tiling.update({ type = "pty_exited", data = { id = 1 } })
assert(#keep_attached_calls == 1, "keep_attached=false: exactly one action taken")
assert(keep_attached_calls[1] == "exit", "keep_attached=false: exits even with other sessions available")
