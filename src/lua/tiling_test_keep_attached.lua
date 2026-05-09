local helpers = require("test_helpers")
local mock_pane = helpers.mock_pane
helpers.setup_prise_mock()

local tiling = require("tiling")
local t = tiling._test

-- === keep_attached ===

local prise_mock = package.loaded["prise"]
local keep_attached_calls = {}

-- Inline delete_session mock. Added here per branches.md rule (test_helpers.lua
-- is frozen for this fix) — the fork's keep_attached path now calls
-- prise.delete_session(current) before switching, and the call must be recorded
-- in keep_attached_calls so tests can assert the ordering.
prise_mock.delete_session = function(name)
    table.insert(keep_attached_calls, "delete_session:" .. name)
    return true
end

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
    -- Re-install the delete_session recorder on every setup so the call list
    -- is scoped to the current test case (keep_attached_calls is re-bound above).
    prise_mock.delete_session = function(name)
        table.insert(keep_attached_calls, "delete_session:" .. name)
        return true
    end
    tiling.setup({ keep_attached = keep })
    t.set_state({
        tabs = { { id = 1, root = mock_pane(1), last_focused_id = 1 } },
        active_tab = 1,
        focused_id = 1,
    })
end

-- Test: keep_attached=true switches to another session when last pane exits
-- After fn-40: delete_session fires FIRST (before the switch loop) so the
-- departing session's state file is removed before any switch attempt — the
-- Zig save branch in switchToSession then honors session_ending and does
-- not re-create the phantom file.
setup_keep_attached_test({ "alpha", "test", "beta" }, "test", true)
tiling.update({ type = "pty_exited", data = { id = 1 } })
assert(#keep_attached_calls == 2, "keep_attached: exactly two actions taken")
assert(keep_attached_calls[1] == "delete_session:test", "keep_attached: deletes current session before switching")
assert(keep_attached_calls[2] == "switch:alpha", "keep_attached: switches to first other session after delete")

-- Test: keep_attached=true exits when no other sessions exist
-- delete_session still fires — the fall-through to prise.exit() relies on
-- the Zig-side idempotent-ENOENT contract so the exit callback's own
-- deleteCurrentSession is a safe no-op on the already-gone file.
setup_keep_attached_test({ "test" }, "test", true)
tiling.update({ type = "pty_exited", data = { id = 1 } })
assert(#keep_attached_calls == 2, "keep_attached no others: exactly two actions taken")
assert(keep_attached_calls[1] == "delete_session:test", "keep_attached no others: deletes current before exit")
assert(keep_attached_calls[2] == "exit", "keep_attached no others: exits when no other sessions")

-- Test: keep_attached=true exits when list_sessions returns nil
setup_keep_attached_test(nil, "test", true)
tiling.update({ type = "pty_exited", data = { id = 1 } })
assert(#keep_attached_calls == 2, "keep_attached nil sessions: exactly two actions taken")
assert(keep_attached_calls[1] == "delete_session:test", "keep_attached nil sessions: deletes current before exit")
assert(keep_attached_calls[2] == "exit", "keep_attached nil sessions: exits when list returns nil")

-- Test: keep_attached=true tries next session when first switch fails
setup_keep_attached_test({ "alpha", "test", "beta" }, "test", true, { "alpha" })
tiling.update({ type = "pty_exited", data = { id = 1 } })
assert(#keep_attached_calls == 3, "keep_attached fallback: deleted then tried two sessions")
assert(keep_attached_calls[1] == "delete_session:test", "keep_attached fallback: deletes current first")
assert(keep_attached_calls[2] == "switch:alpha", "keep_attached fallback: tried alpha after delete")
assert(keep_attached_calls[3] == "switch:beta", "keep_attached fallback: fell through to beta")

-- Test: keep_attached=true exits when all switches fail
setup_keep_attached_test({ "alpha", "test", "beta" }, "test", true, { "alpha", "beta" })
tiling.update({ type = "pty_exited", data = { id = 1 } })
assert(#keep_attached_calls == 4, "keep_attached all fail: deleted, tried both, then exited")
assert(keep_attached_calls[1] == "delete_session:test", "keep_attached all fail: deletes current first")
assert(keep_attached_calls[2] == "switch:alpha", "keep_attached all fail: tried alpha")
assert(keep_attached_calls[3] == "switch:beta", "keep_attached all fail: tried beta")
assert(keep_attached_calls[4] == "exit", "keep_attached all fail: exits after all fail")

-- Test: keep_attached=false always exits
-- No delete_session call on this path — the pre-switch delete lives inside
-- the `if config.keep_attached` branch in tiling.lua. keep_attached=false
-- falls straight through to prise.exit() and the exit callback's
-- deleteCurrentSession is the single source of truth on this path.
setup_keep_attached_test({ "alpha", "test", "beta" }, "test", false)
tiling.update({ type = "pty_exited", data = { id = 1 } })
assert(#keep_attached_calls == 1, "keep_attached=false: exactly one action taken")
assert(keep_attached_calls[1] == "exit", "keep_attached=false: exits even with other sessions available")

-- Test: switch-success ordering — delete_session MUST fire before switch_session
-- (this is the core invariant the Zig-side fix depends on).
setup_keep_attached_test({ "code", "arc" }, "code", true)
tiling.update({ type = "pty_exited", data = { id = 1 } })
assert(#keep_attached_calls == 2, "switch-success ordering: delete then switch")
assert(keep_attached_calls[1] == "delete_session:code", "switch-success ordering: delete_session fires first")
assert(keep_attached_calls[2] == "switch:arc", "switch-success ordering: switch_session fires second")

-- Test: all-switches-fail ordering — delete_session first, then every switch
-- attempt, then exit. Verifies the delete does not live inside the switch
-- loop (would miss the fall-through-to-exit case).
setup_keep_attached_test({ "code", "arc", "arthack" }, "code", true, { "arc", "arthack" })
tiling.update({ type = "pty_exited", data = { id = 1 } })
assert(#keep_attached_calls == 4, "all-fail ordering: delete, two switch attempts, exit")
assert(keep_attached_calls[1] == "delete_session:code", "all-fail ordering: delete_session first")
assert(keep_attached_calls[2] == "switch:arc", "all-fail ordering: tried arc")
assert(keep_attached_calls[3] == "switch:arthack", "all-fail ordering: tried arthack")
assert(keep_attached_calls[4] == "exit", "all-fail ordering: exit after all switches failed")

-- Test: only-session-exists ordering — list_sessions returns {current}, so
-- the switch loop iterates zero times. delete_session still fires, then exit.
setup_keep_attached_test({ "code" }, "code", true)
tiling.update({ type = "pty_exited", data = { id = 1 } })
assert(#keep_attached_calls == 2, "only-session ordering: delete and exit, no switch")
assert(keep_attached_calls[1] == "delete_session:code", "only-session ordering: delete_session fires")
assert(keep_attached_calls[2] == "exit", "only-session ordering: exit fires after delete, no switch call")
