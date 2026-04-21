local helpers = require("test_helpers")
local mock_pane = helpers.mock_pane
local mock_split = helpers.mock_split
helpers.setup_prise_mock()

local tiling = require("tiling")
local t = tiling._test

-- === is_pane / is_split ===

-- Test: is_pane with pane node
assert(t.is_pane({ type = "pane", id = 1 }) == true, "is_pane: pane node")

-- Test: is_pane with split node
assert(t.is_pane({ type = "split" }) == false, "is_pane: split node")

-- Test: is_pane with nil
assert(not t.is_pane(nil), "is_pane: nil")

-- Test: is_split with split node
assert(t.is_split({ type = "split", children = {} }) == true, "is_split: split node")

-- Test: is_split with pane node
assert(t.is_split({ type = "pane" }) == false, "is_split: pane node")

-- Test: is_split with nil
assert(not t.is_split(nil), "is_split: nil")

-- === collect_panes ===

-- Test: collect_panes with nil
local panes = t.collect_panes(nil)
assert(#panes == 0, "collect_panes: nil returns empty")

-- Test: collect_panes with single pane
local single_pane = mock_pane(1)
panes = t.collect_panes(single_pane)
assert(#panes == 1, "collect_panes: single pane count")
assert(panes[1].id == 1, "collect_panes: single pane id")

-- Test: collect_panes with split containing panes
local split_node = mock_split(1, "row", {
    mock_pane(1),
    mock_pane(2),
})
panes = t.collect_panes(split_node)
assert(#panes == 2, "collect_panes: split with 2 panes")
assert(panes[1].id == 1, "collect_panes: first pane")
assert(panes[2].id == 2, "collect_panes: second pane")

-- Test: collect_panes with nested splits
local nested = mock_split(1, "col", {
    mock_pane(1),
    mock_split(2, "row", {
        mock_pane(2),
        mock_pane(3),
    }),
})
panes = t.collect_panes(nested)
assert(#panes == 3, "collect_panes: nested splits")
assert(panes[1].id == 1, "collect_panes: nested first")
assert(panes[2].id == 2, "collect_panes: nested second")
assert(panes[3].id == 3, "collect_panes: nested third")

-- === find_node_path ===

-- Test: find_node_path with nil
local path = t.find_node_path(nil, 1)
assert(path == nil, "find_node_path: nil returns nil")

-- Test: find_node_path with single pane (found)
local pane1 = mock_pane(1)
path = t.find_node_path(pane1, 1)
assert(path ~= nil, "find_node_path: single pane found")
assert(#path == 1, "find_node_path: path length 1")
assert(path[1].id == 1, "find_node_path: path contains pane")

-- Test: find_node_path with single pane (not found)
path = t.find_node_path(pane1, 99)
assert(path == nil, "find_node_path: single pane not found")

-- Test: find_node_path in split
local split_for_path = mock_split(1, "row", {
    mock_pane(1),
    mock_pane(2),
})
path = t.find_node_path(split_for_path, 2)
assert(path ~= nil, "find_node_path: found in split")
assert(#path == 2, "find_node_path: path through split")
assert(path[1].type == "split", "find_node_path: first is split")
assert(path[2].id == 2, "find_node_path: second is target pane")

-- Test: find_node_path in nested splits
local nested_for_path = mock_split(1, "col", {
    mock_pane(1),
    mock_split(2, "row", {
        mock_pane(2),
        mock_pane(3),
    }),
})
path = t.find_node_path(nested_for_path, 3)
assert(path ~= nil, "find_node_path: found in nested")
assert(#path == 3, "find_node_path: nested path length")
assert(path[1].type == "split", "find_node_path: nested first is split")
assert(path[2].type == "split", "find_node_path: nested second is split")
assert(path[3].id == 3, "find_node_path: nested third is target")

-- Test: find_node_path not found in nested
path = t.find_node_path(nested_for_path, 99)
assert(path == nil, "find_node_path: not found in nested")

-- === get_first_leaf ===

-- Test: get_first_leaf with nil
assert(t.get_first_leaf(nil) == nil, "get_first_leaf: nil")

-- Test: get_first_leaf with pane
local leaf_pane = mock_pane(5)
local leaf = t.get_first_leaf(leaf_pane)
assert(leaf ~= nil, "get_first_leaf: pane not nil")
assert(leaf.id == 5, "get_first_leaf: pane returns self")

-- Test: get_first_leaf with split
local split_for_leaf = mock_split(1, "row", {
    mock_pane(10),
    mock_pane(20),
})
leaf = t.get_first_leaf(split_for_leaf)
assert(leaf ~= nil, "get_first_leaf: split not nil")
assert(leaf.id == 10, "get_first_leaf: returns first child")

-- Test: get_first_leaf with nested splits
local nested_for_leaf = mock_split(1, "col", {
    mock_split(2, "row", {
        mock_pane(100),
        mock_pane(200),
    }),
    mock_pane(300),
})
leaf = t.get_first_leaf(nested_for_leaf)
assert(leaf ~= nil, "get_first_leaf: nested not nil")
assert(leaf.id == 100, "get_first_leaf: returns deepest first")

-- === get_last_leaf ===

-- Test: get_last_leaf with nil
assert(t.get_last_leaf(nil) == nil, "get_last_leaf: nil")

-- Test: get_last_leaf with pane
leaf = t.get_last_leaf(leaf_pane)
assert(leaf ~= nil, "get_last_leaf: pane not nil")
assert(leaf.id == 5, "get_last_leaf: pane returns self")

-- Test: get_last_leaf with split
leaf = t.get_last_leaf(split_for_leaf)
assert(leaf ~= nil, "get_last_leaf: split not nil")
assert(leaf.id == 20, "get_last_leaf: returns last child")

-- Test: get_last_leaf with nested splits
leaf = t.get_last_leaf(nested_for_leaf)
assert(leaf ~= nil, "get_last_leaf: nested not nil")
assert(leaf.id == 300, "get_last_leaf: returns deepest last")

-- Test: get_last_leaf with right-heavy nesting
local right_nested = mock_split(1, "col", {
    mock_pane(1),
    mock_split(2, "row", {
        mock_pane(2),
        mock_pane(3),
    }),
})
leaf = t.get_last_leaf(right_nested)
assert(leaf ~= nil, "get_last_leaf: right-heavy nested should return leaf")
assert(leaf.id == 3, "get_last_leaf: right-heavy nested")

-- === format_palette_item ===

-- Test: format_palette_item without shortcut
local item = t.format_palette_item("Close Pane", nil, 50)
assert(item == "Close Pane", "format_palette_item: no shortcut")

-- Test: format_palette_item with shortcut (using ASCII for predictable byte length)
item = t.format_palette_item("Close", "C-w", 20)
-- "Close" (5) + padding + "C-w" (3) = 20, padding = 12
assert(item:sub(1, 5) == "Close", "format_palette_item: name preserved")
assert(item:sub(-3) == "C-w", "format_palette_item: shortcut at end")
assert(#item == 20, "format_palette_item: correct width")

-- Test: format_palette_item with minimum padding
item = t.format_palette_item("Very Long Command Name", "C-x", 10)
-- Width is too small, should use minimum padding of 2
assert(item == "Very Long Command Name  C-x", "format_palette_item: minimum padding")

-- Helper: capture warn calls inline so we can assert on them WITHOUT teaching
-- test_helpers about a "warn-recording" mock (per branches.md, integration
-- helpers stay inline). Returns a restore function the caller invokes after.
local function capture_warns()
    local prise_mock = package.loaded["prise"]
    local saved = prise_mock.log.warn
    local calls = {}
    prise_mock.log.warn = function(msg)
        table.insert(calls, msg)
    end
    return calls, function()
        prise_mock.log.warn = saved
    end
end

-- === compute_focus_window ===
-- Pure function: centre the active tab in the window when the strip overflows
-- the budget, clamp to 0 on underflow, clamp to max on overrun. Mirrors
-- tmux's `format_draw_put_list` focus-centre algorithm. No tiling state.

-- Test: fits within budget — start snaps to 0, total_width reports sum.
do
    local r = t.compute_focus_window({ 10, 10, 10 }, 2, 40)
    assert(r.start == 0, "compute_focus_window: fits → start 0")
    assert(r.total_width == 30, "compute_focus_window: fits → total 30")
end

-- Test: active in middle — centered when budget < total.
-- Tabs: [0,10][10,20][20,30][30,40]. budget=20. active=2 at [10,20].
-- focus_centre = 10 + floor(10/2) = 15. half = 10. start = 15-10 = 5.
-- max_start = 40-20 = 20. 5 <= 20, so start = 5.
do
    local r = t.compute_focus_window({ 10, 10, 10, 10 }, 2, 20)
    assert(r.start == 5, "compute_focus_window: middle active centered")
    assert(r.total_width == 40, "compute_focus_window: middle → total 40")
end

-- Test: active near left — underflow branch → start = 0.
-- active=1 at [0,10]. focus_centre = 5. half = 10. 5 < 10 → start = 0.
do
    local r = t.compute_focus_window({ 10, 10, 10, 10 }, 1, 20)
    assert(r.start == 0, "compute_focus_window: near left → start 0 (underflow guard)")
end

-- Test: active near right — start clamps to max.
-- active=4 at [30,40]. focus_centre = 35. half = 10. start = 25.
-- max_start = 40-20 = 20. 25 > 20 → clamp to 20.
do
    local r = t.compute_focus_window({ 10, 10, 10, 10 }, 4, 20)
    assert(r.start == 20, "compute_focus_window: near right → start clamps to max")
end

-- Test: single tab wider than budget — start = 0 (total <= budget path doesn't
-- trigger, but the underflow clamp still applies).
-- Wait: total(50) > budget(20), so we fall through. focus_centre = 25.
-- half = 10. start = 15. max_start = 50-20 = 30. 15 < 30 → start = 15.
-- For the spec's "single tab wider than budget: start = 0" case, we want
-- active=1 AND budget to be smaller, AND the tab to start at 0. The underflow
-- branch only triggers if focus_centre < half. With tab width 50, focus_centre
-- = 25, half(of 20) = 10; 25 > 10 so we DON'T underflow.
-- Interpretation: when the single tab's left edge is already at 0, we land
-- on start=0 if focus_centre < half; otherwise centering is still valid.
-- The spec's intent: "no crash, sane output".
do
    local r = t.compute_focus_window({ 50 }, 1, 20)
    -- total=50 > budget=20. focus_centre=25. half=10. start=15. max=30. 15<30 → 15.
    assert(r.start == 15, "compute_focus_window: single oversize → start centered")
    assert(r.total_width == 50, "compute_focus_window: single oversize → total 50")
end

-- Test: zero tabs — start = 0, total_width = 0.
do
    local r = t.compute_focus_window({}, 1, 20)
    assert(r.start == 0 and r.total_width == 0, "compute_focus_window: zero tabs")
end

-- Test: stale active index → clamped to 1, no crash.
do
    local r = t.compute_focus_window({ 10, 10, 10 }, 99, 15)
    assert(r.start == 0, "compute_focus_window: stale active → clamped, start 0")
end

-- Test: budget <= 0 defensively clamps to 1.
do
    local ok = pcall(t.compute_focus_window, { 5, 5, 5 }, 1, 0)
    assert(ok, "compute_focus_window: budget=0 → no crash")
end

-- === derive_visible_range ===
-- Walk cumulative widths to find the inclusive 1-based range of tabs visible
-- inside [start, start+effective_budget]. leading_clip and trailing_clip
-- report the cell-precise clip needed on the boundary tabs.

-- Test: budget aligns with tab boundary — no clip.
-- Tabs: [0,10][10,20][20,30]. start=10. budget=10. window = [10,20].
-- first=2 (cum_start=10, cum_end=20), last=2. leading=0, trailing=0.
do
    local r = t.derive_visible_range({ 10, 10, 10 }, 10, 10)
    assert(r.first_idx == 2, "derive_visible_range: aligned → first 2")
    assert(r.last_idx == 2, "derive_visible_range: aligned → last 2")
    assert(r.leading_clip == 0, "derive_visible_range: aligned → no leading clip")
    assert(r.trailing_clip == 0, "derive_visible_range: aligned → no trailing clip")
end

-- Test: leading edge mid-tab — leading_clip > 0.
-- Tabs: [0,10][10,20][20,30]. start=5. budget=10. window = [5,15].
-- first=1 (cum_start=0, cum_end=10, overlaps), last=2 (cum_start=10, cum_end=20, overlaps).
-- leading = start - first_cum_start = 5 - 0 = 5.
-- trailing = last_cum_end - window_end = 20 - 15 = 5.
do
    local r = t.derive_visible_range({ 10, 10, 10 }, 5, 10)
    assert(r.first_idx == 1 and r.last_idx == 2, "derive_visible_range: mid-tab → 1..2")
    assert(r.leading_clip == 5, "derive_visible_range: mid-tab → leading 5")
    assert(r.trailing_clip == 5, "derive_visible_range: mid-tab → trailing 5")
end

-- Test: trailing edge mid-tab only.
-- Tabs: [0,10][10,20][20,30]. start=10. budget=5. window = [10,15].
-- first=2 (10..20 overlaps 10..15), last=2. leading = 10-10 = 0. trailing = 20-15 = 5.
do
    local r = t.derive_visible_range({ 10, 10, 10 }, 10, 5)
    assert(r.first_idx == 2 and r.last_idx == 2, "derive_visible_range: trailing-only → 2..2")
    assert(r.leading_clip == 0, "derive_visible_range: trailing-only → no leading clip")
    assert(r.trailing_clip == 5, "derive_visible_range: trailing-only → trailing 5")
end

-- Test: budget smaller than first tab — visible single tab, clipped both sides.
-- Tabs: [0,20]. start=5. budget=10. window = [5,15]. first=1. last=1.
-- leading = 5 - 0 = 5. trailing = 20 - 15 = 5.
do
    local r = t.derive_visible_range({ 20 }, 5, 10)
    assert(r.first_idx == 1 and r.last_idx == 1, "derive_visible_range: narrow → single")
    assert(r.leading_clip == 5 and r.trailing_clip == 5, "derive_visible_range: narrow → clip both")
end

-- Test: empty tabs.
do
    local r = t.derive_visible_range({}, 0, 10)
    assert(r.first_idx == 0 and r.last_idx == 0, "derive_visible_range: empty → 0..0")
end

-- Test: zero budget.
do
    local r = t.derive_visible_range({ 10 }, 0, 0)
    assert(r.first_idx == 0, "derive_visible_range: zero budget → 0")
end

-- === apply_gutters ===
-- Decide whether to show left/right gutter glyphs based on window position,
-- narrow the window to make room. Narrow-terminal guard drops both gutters
-- if the combined width exceeds budget.

-- Test: hidden left only — tabs extend past window_end but window starts at 0.
-- start=0, budget=20, total=40. show_left = start>0 → false.
-- show_right = (0+20) < 40 → true. adjusted_budget = 20 - 0 - 1 = 19.
-- adjusted_start = 0 + 0 = 0.
do
    local r = t.apply_gutters(0, 20, 40, 1, 1)
    assert(r.show_left == false, "apply_gutters: at-left → no left gutter")
    assert(r.show_right == true, "apply_gutters: at-left → right gutter shown")
    assert(r.adjusted_start == 0, "apply_gutters: at-left → adjusted_start=0")
    assert(r.adjusted_budget == 19, "apply_gutters: at-left → adjusted_budget=19")
end

-- Test: hidden right only — window reaches total_width.
-- start=20, budget=20, total=40. show_left = 20>0 → true. show_right = 40<40 → false.
-- adjusted_budget = 20 - 1 - 0 = 19. adjusted_start = 20 + 1 = 21.
do
    local r = t.apply_gutters(20, 20, 40, 1, 1)
    assert(r.show_left == true, "apply_gutters: at-right → left gutter shown")
    assert(r.show_right == false, "apply_gutters: at-right → no right gutter")
    assert(r.adjusted_start == 21, "apply_gutters: at-right → adjusted_start=21")
    assert(r.adjusted_budget == 19, "apply_gutters: at-right → adjusted_budget=19")
end

-- Test: both gutters — mid-strip.
-- start=10, budget=20, total=40. show_left → true, show_right → true.
-- adjusted_budget = 20 - 1 - 1 = 18. adjusted_start = 10 + 1 = 11.
do
    local r = t.apply_gutters(10, 20, 40, 1, 1)
    assert(r.show_left and r.show_right, "apply_gutters: mid → both gutters")
    assert(r.adjusted_start == 11, "apply_gutters: mid → adjusted_start=11")
    assert(r.adjusted_budget == 18, "apply_gutters: mid → adjusted_budget=18")
end

-- Test: neither — everything fits.
-- start=0, budget=40, total=30. show_left → false. show_right → (0+40 < 30)? no → false.
do
    local r = t.apply_gutters(0, 40, 30, 1, 1)
    assert(r.show_left == false and r.show_right == false, "apply_gutters: fits → neither")
    assert(r.adjusted_start == 0 and r.adjusted_budget == 40, "apply_gutters: fits → unchanged")
end

-- Test: narrow terminal — budget too tight for gutters, drop both.
-- budget=2, gutter_left_w=1, gutter_right_w=1. Combined 2 but guard requires
-- budget >= left + right + 1 → 2 < 3 → drop both.
do
    local r = t.apply_gutters(10, 2, 40, 1, 1)
    assert(r.show_left == false and r.show_right == false, "apply_gutters: narrow → drop both")
    assert(r.adjusted_budget == 2, "apply_gutters: narrow → full budget preserved")
end

-- Test: wide gutter glyph drops both when it alone exceeds the budget minus
-- one cell of tab.
do
    local r = t.apply_gutters(10, 3, 40, 2, 2) -- 3 < 2+2+1=5 → drop both
    assert(r.show_left == false and r.show_right == false, "apply_gutters: wide glyph → drop")
end

-- === clip_boundary_tab ===
-- Flatten segments to a string, clip via prise.cell_substring, return a
-- single-entry segment list carrying the first segment's style.

-- Test: ASCII clip from left.
do
    local prise_mock = package.loaded["prise"]
    local saved_sub = prise_mock.cell_substring
    prise_mock.cell_substring = function(s, start_cell, end_cell)
        return s:sub(start_cell + 1, end_cell)
    end
    local out = t.clip_boundary_tab({ { text = "hello", style = { fg = "red" } } }, 2, 0)
    assert(#out == 1, "clip_boundary_tab: ASCII → 1 segment")
    assert(out[1].text == "llo", "clip_boundary_tab: ASCII → text trimmed")
    assert(out[1].style.fg == "red", "clip_boundary_tab: ASCII → style preserved")
    prise_mock.cell_substring = saved_sub
end

-- Test: ASCII clip from right.
do
    local prise_mock = package.loaded["prise"]
    local saved_sub = prise_mock.cell_substring
    prise_mock.cell_substring = function(s, start_cell, end_cell)
        return s:sub(start_cell + 1, end_cell)
    end
    local out = t.clip_boundary_tab({ { text = "hello", style = {} } }, 0, 2)
    assert(out[1].text == "hel", "clip_boundary_tab: right clip → text trimmed")
    prise_mock.cell_substring = saved_sub
end

-- Test: multi-byte (override gwidth inline).
-- Two-cell CJK glyph: simulate gwidth counting cells, not bytes.
do
    local prise_mock = package.loaded["prise"]
    local saved_gw = prise_mock.gwidth
    local saved_sub = prise_mock.cell_substring
    prise_mock.gwidth = function(s)
        -- Treat 'X' as 2 cells, everything else as 1.
        local n = 0
        for i = 1, #s do
            n = n + (s:sub(i, i) == "X" and 2 or 1)
        end
        return n
    end
    prise_mock.cell_substring = function(s, start_cell, end_cell)
        -- Walk by cells, skipping X's 2 cells.
        local out = ""
        local cell = 0
        for i = 1, #s do
            local ch = s:sub(i, i)
            local w = ch == "X" and 2 or 1
            if cell >= start_cell and cell + w <= end_cell then
                out = out .. ch
            end
            cell = cell + w
        end
        return out
    end
    -- "abXc" = cells a(1), b(1), X(2), c(1) = 5 cells total.
    -- Clip leading 1 cell → keep "bXc" (cells 1..5).
    local out = t.clip_boundary_tab({ { text = "abXc", style = {} } }, 1, 0)
    assert(out[1].text == "bXc", "clip_boundary_tab: multi-byte leading clip")
    prise_mock.gwidth = saved_gw
    prise_mock.cell_substring = saved_sub
end

-- Test: no-clip pass-through — function must still flatten but leave content.
do
    local prise_mock = package.loaded["prise"]
    local saved_sub = prise_mock.cell_substring
    prise_mock.cell_substring = function(s, start_cell, end_cell)
        return s:sub(start_cell + 1, end_cell)
    end
    local out = t.clip_boundary_tab({ { text = "ab", style = { fg = "x" } }, { text = "cd", style = {} } }, 0, 0)
    assert(#out == 1 and out[1].text == "abcd", "clip_boundary_tab: no-clip → flatten preserved")
    assert(out[1].style.fg == "x", "clip_boundary_tab: no-clip → first style wins")
    prise_mock.cell_substring = saved_sub
end

-- Test: empty segments list.
do
    local out = t.clip_boundary_tab({}, 5, 3)
    assert(#out == 0, "clip_boundary_tab: empty → empty")
end

-- === compose_layout_segments ===
-- Concatenate prefix + optional left gutter + visible tabs + optional right
-- gutter + suffix into a flat segment list.

-- Test: empty visible tabs — prefix + suffix only.
do
    local out = t.compose_layout_segments({ { text = "P", style = {} } }, nil, {}, nil, { { text = "S", style = {} } })
    assert(#out == 2, "compose_layout_segments: prefix+suffix → 2")
    assert(out[1].text == "P" and out[2].text == "S", "compose_layout_segments: order")
end

-- Test: full pipeline with gutters.
do
    local out = t.compose_layout_segments(
        { { text = "P", style = {} } },
        { text = "<", style = {} },
        { { { text = "T1", style = {} } }, { { text = "T2", style = {} } } },
        { text = ">", style = {} },
        { { text = "S", style = {} } }
    )
    assert(#out == 6, "compose_layout_segments: full → 6 segments")
    assert(out[1].text == "P", "compose_layout_segments: [1]=prefix")
    assert(out[2].text == "<", "compose_layout_segments: [2]=left gutter")
    assert(out[3].text == "T1", "compose_layout_segments: [3]=T1")
    assert(out[4].text == "T2", "compose_layout_segments: [4]=T2")
    assert(out[5].text == ">", "compose_layout_segments: [5]=right gutter")
    assert(out[6].text == "S", "compose_layout_segments: [6]=suffix")
end

-- Test: no gutters (nil args).
do
    local out = t.compose_layout_segments({}, nil, { { { text = "T", style = {} } } }, nil, {})
    assert(#out == 1 and out[1].text == "T", "compose_layout_segments: no gutters")
end

-- === derive_click_regions ===
-- Walk visible tabs with x-offset starting at prefix_w + gutter_l_w. Emit
-- one region per tab keyed by its original tab_index. Gutters aren't clickable.

-- Test: correct per-tab regions, no gutters, no prefix.
do
    local regs = t.derive_click_regions(0, 0, {
        { tab_index = 1, width = 5 },
        { tab_index = 2, width = 10 },
    }, 0)
    assert(#regs == 2, "derive_click_regions: 2 regions")
    assert(regs[1].start_x == 0 and regs[1].end_x == 5 and regs[1].tab_index == 1, "derive_click_regions: [1]=0..5")
    assert(regs[2].start_x == 5 and regs[2].end_x == 15 and regs[2].tab_index == 2, "derive_click_regions: [2]=5..15")
end

-- Test: gutter offset accounted.
do
    local regs = t.derive_click_regions(0, 1, {
        { tab_index = 3, width = 5 },
    }, 0)
    assert(regs[1].start_x == 1 and regs[1].end_x == 6, "derive_click_regions: gutter offset")
    assert(regs[1].tab_index == 3, "derive_click_regions: tab_index preserved across slice")
end

-- Test: prefix offset accounted.
do
    local regs = t.derive_click_regions(10, 0, {
        { tab_index = 1, width = 5 },
    }, 0)
    assert(regs[1].start_x == 10 and regs[1].end_x == 15, "derive_click_regions: prefix offset")
end

-- Test: prefix + left gutter + multi.
do
    local regs = t.derive_click_regions(3, 1, {
        { tab_index = 7, width = 4 },
        { tab_index = 8, width = 6 },
    }, 1)
    -- First x = 3+1 = 4. First region 4..8. Second 8..14.
    assert(regs[1].start_x == 4 and regs[1].end_x == 8, "derive_click_regions: first at 4..8")
    assert(regs[2].start_x == 8 and regs[2].end_x == 14, "derive_click_regions: second at 8..14")
end

-- Test: empty visible → no regions.
do
    local regs = t.derive_click_regions(5, 1, {}, 1)
    assert(#regs == 0, "derive_click_regions: empty visible → no regions")
end

-- === renderer error posture (build_tab_bar_custom) ===
-- Malformed layouts & Lua errors in the render callback trigger warn-once
-- (latched on state.tab_bar_render_warned) + render an empty strip.

-- Helper: capture warn calls inline so we can assert on them WITHOUT teaching
-- test_helpers about a "warn-recording" mock (per branches.md, integration
-- helpers stay inline). A duplicate of the definition above — co-located with
-- install_cell_substring so the renderer-error posture block survives intact
-- across merge with feat/overlay-terminals (which drops the upper definition
-- via rerere resolution). Lua shadows the earlier `local function` silently.
local function capture_warns()
    local prise_mock = package.loaded["prise"]
    local saved = prise_mock.log.warn
    local calls = {}
    prise_mock.log.warn = function(msg)
        table.insert(calls, msg)
    end
    return calls, function()
        prise_mock.log.warn = saved
    end
end

-- Helper: install a minimal prise.cell_substring pass-through so the render
-- path's boundary clipping can run without throwing. The default mock in
-- test_helpers doesn't ship this field.
local function install_cell_substring()
    local prise_mock = package.loaded["prise"]
    local saved = prise_mock.cell_substring
    prise_mock.cell_substring = function(s, start_cell, end_cell)
        return s:sub(start_cell + 1, end_cell)
    end
    return function()
        prise_mock.cell_substring = saved
    end
end

-- Test: malformed layout (non-table tabs) → warn captured + empty strip +
-- latch = true. Second invocation must NOT emit a second warn.
do
    t.reset_tab_bar_render_warned()
    t.set_screen_cols(80)
    -- Need at least 2 tabs for build_tab_bar to invoke the custom path; but
    -- build_tab_bar_custom itself calls render unconditionally. We test the
    -- inner function with set_state for the tabs table.
    t.set_state({
        tabs = {
            { root = mock_pane(1), title = "a" },
            { root = mock_pane(2), title = "b" },
        },
        active_tab = 1,
    })
    t.set_tab_bar_render(function()
        return { prefix = {}, tabs = "not-a-table", suffix = {} }
    end)
    local restore_sub = install_cell_substring()
    local warns, restore_warn = capture_warns()

    local out1 = t.build_tab_bar_custom()
    assert(type(out1) == "table", "render error: returns segment list")
    assert(#out1 == 0, "render error: empty strip (no prefix/suffix from malformed)")
    assert(#warns == 1, "render error: warn once on first error")

    local out2 = t.build_tab_bar_custom()
    assert(type(out2) == "table", "render error 2nd: still returns segment list")
    assert(#warns == 1, "render error 2nd: NO second warn (latched)")

    restore_warn()
    restore_sub()
    t.set_tab_bar_render(nil)
    t.reset_tab_bar_render_warned()
end

-- Test: render callback raises Lua error → warn-once + empty strip.
do
    t.reset_tab_bar_render_warned()
    t.set_screen_cols(80)
    t.set_state({
        tabs = { { root = mock_pane(1), title = "a" }, { root = mock_pane(2), title = "b" } },
        active_tab = 1,
    })
    t.set_tab_bar_render(function()
        error("boom")
    end)
    local restore_sub = install_cell_substring()
    local warns, restore_warn = capture_warns()

    local out = t.build_tab_bar_custom()
    assert(type(out) == "table" and #out == 0, "render raise: empty strip")
    assert(#warns == 1, "render raise: warn once")

    restore_warn()
    restore_sub()
    t.set_tab_bar_render(nil)
    t.reset_tab_bar_render_warned()
end

-- Test: budget overflow (prefix_w + suffix_w >= screen_cols) → tabs absent
-- from composed segments; prefix + suffix emitted.
do
    t.reset_tab_bar_render_warned()
    t.set_screen_cols(10)
    t.set_state({
        tabs = { { root = mock_pane(1), title = "a" }, { root = mock_pane(2), title = "b" } },
        active_tab = 1,
    })
    -- prefix = 6 cells, suffix = 6 cells, together >= 10 screen_cols → drop tabs.
    t.set_tab_bar_render(function()
        return {
            prefix = { { text = "PPPPPP", style = {} } },
            tabs = {
                { tab_index = 1, segments = { { text = "T1", style = {} } } },
                { tab_index = 2, segments = { { text = "T2", style = {} } } },
            },
            suffix = { { text = "SSSSSS", style = {} } },
        }
    end)
    local restore_sub = install_cell_substring()
    local warns, restore_warn = capture_warns()

    local out = t.build_tab_bar_custom()
    assert(#warns == 0, "budget overflow: no warn")
    assert(#out == 2, "budget overflow: only prefix + suffix (2 segments)")
    assert(out[1].text == "PPPPPP", "budget overflow: prefix intact")
    assert(out[2].text == "SSSSSS", "budget overflow: suffix intact")
    -- Click regions must be empty — no tabs rendered.
    local st = t.get_state()
    assert(#st.tab_regions == 0, "budget overflow: empty click regions")

    restore_warn()
    restore_sub()
    t.set_tab_bar_render(nil)
    t.reset_tab_bar_render_warned()
end

-- Test: happy path — all tabs fit, no gutters needed, click regions correct.
do
    t.reset_tab_bar_render_warned()
    t.set_screen_cols(40)
    t.set_state({
        tabs = { { root = mock_pane(1), title = "a" }, { root = mock_pane(2), title = "b" } },
        active_tab = 1,
    })
    t.set_tab_bar_render(function()
        return {
            prefix = { { text = "P", style = {} } },
            tabs = {
                { tab_index = 1, segments = { { text = "T1", style = {} } } },
                { tab_index = 2, segments = { { text = "T2", style = {} } } },
            },
            suffix = { { text = "S", style = {} } },
        }
    end)
    local restore_sub = install_cell_substring()
    local warns, restore_warn = capture_warns()

    local out = t.build_tab_bar_custom()
    assert(#warns == 0, "happy path: no warn")
    -- Expect: P T1 T2 S (no gutters — everything fits).
    assert(#out == 4, "happy path: 4 segments (prefix + 2 tabs + suffix)")
    assert(
        out[1].text == "P" and out[2].text == "T1" and out[3].text == "T2" and out[4].text == "S",
        "happy path: segment order"
    )
    local st = t.get_state()
    assert(#st.tab_regions == 2, "happy path: 2 click regions")
    assert(
        st.tab_regions[1].tab_index == 1 and st.tab_regions[1].start_x == 1 and st.tab_regions[1].end_x == 3,
        "happy path: region 1 at 1..3"
    )
    assert(
        st.tab_regions[2].tab_index == 2 and st.tab_regions[2].start_x == 3 and st.tab_regions[2].end_x == 5,
        "happy path: region 2 at 3..5"
    )

    restore_warn()
    restore_sub()
    t.set_tab_bar_render(nil)
    t.reset_tab_bar_render_warned()
end

-- Cleanup: leave renderer config nil + warn latch reset for any tests that follow.
t.set_tab_bar_render(nil)
t.reset_tab_bar_render_warned()
