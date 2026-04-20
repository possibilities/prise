--- Tests for M.view() dispatch during session-switch transition window.
---
--- Covers the three-way dispatch introduced in fn-63:
---   1. #state.tabs == 0  → full-screen placeholder (Column > Text "Waiting...")
---   2. #state.tabs > 0, active root nil  → build_transition_shell() output
---   3. #state.tabs > 0, active root nil, show_single_tab=false  → tab bar still present
---   4. After set_state (roots populated)  → main render path (Terminal widget present)
local helpers = require("test_helpers")
local mock_pty = helpers.mock_pty
helpers.setup_prise_mock()

local tiling = require("tiling")
local t = tiling._test

-- Helper: find first child of widget matching type, returns nil if absent.
local function find_child(widget, child_type)
    if not widget or not widget.children then
        return nil
    end
    for _, child in ipairs(widget.children) do
        if child and child.type == child_type then
            return child
        end
    end
    return nil
end

-- Helper: find any descendant (depth-first) matching type.
local function find_descendant(widget, target_type)
    if not widget then
        return nil
    end
    if widget.type == target_type then
        return widget
    end
    if widget.children then
        for _, child in ipairs(widget.children) do
            local found = find_descendant(child, target_type)
            if found then
                return found
            end
        end
    end
    return nil
end

-- === Case 1: genuine no-session — #state.tabs == 0 → placeholder ===

tiling.set_tab_shell({ tabs = {}, active_tab = 1, next_tab_id = 1 })
local result = tiling.view()

assert(result ~= nil, "no-session: view() returns non-nil")
assert(result.type == "column", "no-session: root is column")
-- Must contain a Text widget (the "Waiting for terminal..." placeholder).
local placeholder_text = find_child(result, "text")
assert(placeholder_text ~= nil, "no-session: column contains a text child")

print("Case 1 (no-session placeholder): passed")

-- === Case 2: post-set_tab_shell multi-tab — transition shell ===

local plan_two_tabs = {
    tabs = {
        { id = 1, title = "alpha", last_focused_id = 11, root = { type = "pane", id = 11, pty_id = 11 } },
        { id = 2, title = "beta", last_focused_id = 22, root = { type = "pane", id = 22, pty_id = 22 } },
    },
    active_tab = 1,
    next_tab_id = 3,
}

tiling.set_tab_shell(plan_two_tabs)
result = tiling.view()

assert(result ~= nil, "multi-tab transition: view() returns non-nil")
assert(result.type == "column", "multi-tab transition: root is column")
-- Tab bar must be present (forced visible regardless of show_single_tab).
local tab_bar = find_child(result, "text")
assert(tab_bar ~= nil, "multi-tab transition: tab bar (text widget) present")
-- Empty-pane column must be present as a child column.
local pane_col = find_child(result, "column")
assert(pane_col ~= nil, "multi-tab transition: empty pane column present")
-- No Terminal widgets — no pty refs should appear in the tree.
local terminal = find_descendant(result, "terminal")
assert(terminal == nil, "multi-tab transition: no Terminal widget (no pty refs)")

print("Case 2 (multi-tab transition shell): passed")

-- === Case 3: single-tab with show_single_tab=false — tab bar still forced visible ===

-- Apply config that would normally hide the tab bar for a single tab.
tiling.setup({ tab_bar = { show_single_tab = false } })

local plan_one_tab = {
    tabs = {
        { id = 1, title = "only", last_focused_id = 11, root = { type = "pane", id = 11, pty_id = 11 } },
    },
    active_tab = 1,
    next_tab_id = 2,
}

tiling.set_tab_shell(plan_one_tab)
result = tiling.view()

assert(result ~= nil, "single-tab transition: view() returns non-nil")
assert(result.type == "column", "single-tab transition: root is column")
-- Tab bar must still be present despite show_single_tab=false.
tab_bar = find_child(result, "text")
assert(tab_bar ~= nil, "single-tab transition: tab bar present even with show_single_tab=false")
-- No Terminal widgets.
terminal = find_descendant(result, "terminal")
assert(terminal == nil, "single-tab transition: no Terminal widget")

print("Case 3 (single-tab, show_single_tab=false): passed")

-- Reset config back to default for Case 4.
tiling.setup({ tab_bar = { show_single_tab = true } })

-- === Case 4: post-set_state (roots populated) — main render path ===

local live_ptys = {
    [11] = mock_pty(11),
    [22] = mock_pty(22),
}
local function live_lookup(id)
    return live_ptys[id]
end

tiling.set_state({
    tabs = {
        { id = 1, title = "alpha", last_focused_id = 11, root = { type = "pane", id = 11, pty_id = 11 } },
        { id = 2, title = "beta", last_focused_id = 22, root = { type = "pane", id = 22, pty_id = 22 } },
    },
    active_tab = 1,
    next_tab_id = 3,
}, live_lookup)

result = tiling.view()

assert(result ~= nil, "post-set_state: view() returns non-nil")
-- Must not be the placeholder column (it would have a "text" direct child with no tab structure).
local state = t.get_state()
assert(state.tabs[1].root ~= nil, "post-set_state: root is populated")
-- A Terminal widget must appear somewhere in the tree (main render path ran).
terminal = find_descendant(result, "terminal")
assert(terminal ~= nil, "post-set_state: Terminal widget present in tree")

print("Case 4 (post-set_state main render): passed")

print("view transition shell: all cases passed")
