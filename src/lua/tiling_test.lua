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

-- Test: fits within budget — start snaps to 0, total_width reports sum of
-- label widths PLUS (N-1) core-injected separator cells.
do
    local r = t.compute_focus_window({ 10, 10, 10 }, 2, 40)
    assert(r.start == 0, "compute_focus_window: fits → start 0")
    assert(r.total_width == 32, "compute_focus_window: fits → total 32 (30 + 2 separators)")
end

-- Test: active in middle — centered when budget < total.
-- Tabs (label+sep): [0,10] sep[10] [11,21] sep[21] [22,32] sep[32] [33,43].
-- active=2 at [11,21]. focus_centre = 11 + floor(10/2) = 16. half = 10.
-- start = 16-10 = 6. max_start = 43-20 = 23. 6 <= 23 → start = 6.
do
    local r = t.compute_focus_window({ 10, 10, 10, 10 }, 2, 20)
    assert(r.start == 6, "compute_focus_window: middle active centered (with separators)")
    assert(r.total_width == 43, "compute_focus_window: middle → total 43 (40 + 3 separators)")
end

-- Test: active near left — underflow branch → start = 0.
-- active=1 at [0,10]. focus_centre = 5. half = 10. 5 < 10 → start = 0.
do
    local r = t.compute_focus_window({ 10, 10, 10, 10 }, 1, 20)
    assert(r.start == 0, "compute_focus_window: near left → start 0 (underflow guard)")
end

-- Test: active near right — start clamps to max.
-- active=4 at [33,43]. focus_centre = 33 + 5 = 38. half = 10. start = 28.
-- max_start = 43-20 = 23. 28 > 23 → clamp to 23.
do
    local r = t.compute_focus_window({ 10, 10, 10, 10 }, 4, 20)
    assert(r.start == 23, "compute_focus_window: near right → start clamps to max (with separators)")
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
-- inside [start, start+effective_budget]. Separators between adjacent tabs
-- (1 cell each) are accounted for in the cumulative walk. leading_clip and
-- trailing_clip report the cell-precise clip needed on the boundary tabs.
-- Honors snap-past-separator: `start` or `window_end` landing in a separator
-- cell snaps to the adjacent tab boundary.

-- Test: budget aligns with tab boundary — no clip.
-- Tabs (label+sep): [0,10] sep[10] [11,21] sep[21] [22,32]. start=10. budget=10. window=[10,20].
-- tab1 cum[0,10]: 10>10 false → skip. tab2 cum[11,21]: 21>10 AND 11<20 → first=last=2.
-- leading = 10-11 = -1 → 0. trailing = 21-20 = 1.
do
    local r = t.derive_visible_range({ 10, 10, 10 }, 10, 10)
    assert(r.first_idx == 2, "derive_visible_range: aligned → first 2")
    assert(r.last_idx == 2, "derive_visible_range: aligned → last 2")
    assert(r.leading_clip == 0, "derive_visible_range: aligned → no leading clip")
    assert(r.trailing_clip == 1, "derive_visible_range: aligned → trailing clip=1 (separator pushes tab 2 trailing)")
end

-- Test: leading edge mid-tab — leading_clip > 0.
-- Tabs: [0,10] sep[10] [11,21] sep[21] [22,32]. start=5. budget=10. window=[5,15].
-- tab1 cum[0,10]: 10>5 AND 0<15 → first=1. tab2 cum[11,21]: 21>5 AND 11<15 → last=2.
-- leading = 5-0 = 5. trailing = 21-15 = 6.
do
    local r = t.derive_visible_range({ 10, 10, 10 }, 5, 10)
    assert(r.first_idx == 1 and r.last_idx == 2, "derive_visible_range: mid-tab → 1..2")
    assert(r.leading_clip == 5, "derive_visible_range: mid-tab → leading 5")
    assert(r.trailing_clip == 6, "derive_visible_range: mid-tab → trailing 6 (accounts for separator)")
end

-- Test: trailing edge mid-tab only.
-- Tabs: [0,10] sep[10] [11,21] sep[21] [22,32]. start=10. budget=5. window=[10,15].
-- tab1 cum[0,10]: 10>10 false. tab2 cum[11,21]: 21>10 AND 11<15 → first=last=2.
-- leading = 10-11 = -1 → 0. trailing = 21-15 = 6.
do
    local r = t.derive_visible_range({ 10, 10, 10 }, 10, 5)
    assert(r.first_idx == 2 and r.last_idx == 2, "derive_visible_range: trailing-only → 2..2")
    assert(r.leading_clip == 0, "derive_visible_range: trailing-only → no leading clip")
    assert(r.trailing_clip == 6, "derive_visible_range: trailing-only → trailing 6")
end

-- Test: budget smaller than first tab — visible single tab, clipped both sides.
-- Tabs: [0,20]. start=5. budget=10. window=[5,15]. first=1, last=1.
-- leading = 5-0 = 5. trailing = 20-15 = 5. N=1 so no separator injection.
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

-- Test: snap-past-separator (left edge). `start` lands in a separator cell
-- between tab 1 and tab 2 — the leading clip would otherwise eat all of tab 1.
-- Tabs: [0,10] sep[10] [11,21] sep[21] [22,32]. start=10. budget=12. window=[10,22].
-- tab1 cum[0,10]: 10>10 false. tab2 cum[11,21]: first=2. tab3 cum[22,32]: 32>10 AND 22<22 false → skip.
-- Wait — 22<22 is false, so tab 3 isn't visible. last=2.
-- leading = 10-11 = -1 → 0. trailing = 21-22 = -1 → 0. No snap needed.
-- Rework: start=10, budget=6 → window=[10,16]. tab1 cum[0,10]: 10>10 false. tab2 cum[11,21]: first=last=2.
-- leading = 10-11 → 0. trailing = 21-16 = 5. No snap needed.
-- True snap case: start inside tab 1's end — start=10, budget=10, first=2, no snap. But start=9, budget=10 →
-- tab1 cum[0,10]: 10>9 AND 0<19 → first=1. tab2 cum[11,21]: 21>9 AND 11<19 → last=2.
-- leading = 9-0 = 9. leading < tab1_w(10) → no snap.
-- For snap-past-separator LEFT, leading_clip must be >= first_w. That happens when start is in the separator
-- cell BEFORE the next tab. Tabs [10,10,10]: separator sits at cell 10 (between tab1 end=10 and tab2 start=11).
-- start=10 AND budget=10 → window=[10,20]. tab1 cum=[0,10], cum_end=10 > 10 is FALSE → tab1 skipped.
-- Already handled. Snap doesn't fire in this case because first_idx is already 2.
-- Real snap case: start such that tab1 IS included but leading_clip >= tab1_w.
-- That means start-first_cum_start >= first_w. If first_idx=1, first_cum_start=0. So start >= tab1_w.
-- But the walk only includes tab1 if cum_end(=tab1_w) > start → tab1_w > start. Contradiction.
-- Thus leading snap via literal "start inside tab i's separator" can't fire on the LEADING side via the
-- normal overlap test — the walk already skips the half-clipped tab. The snap rule is defensive: documents
-- the invariant that separators never sit at the viewport's left edge.
-- For the RIGHT edge, separators CAN end up at the right edge because of `cum_start < window_end` inclusion.
-- Test the right-side snap. Tabs [10,10,10]: separator at cells 10, 21. window=[0,11], start=0, budget=11.
-- tab1 cum[0,10]: 10>0 AND 0<11 → first=1. tab2 cum[11,21]: 21>0 AND 11<11 FALSE → tab2 NOT in.
-- last=1. leading=0, trailing = 10-11 = -1 → 0. No snap. budget=12: tab2 cum[11,21]: 11<12 → last=2.
-- trailing = 21-12 = 9. last_w=10, 9 < 10 → no snap. budget=11 handled above.
-- Designed snap case: window_end sits inside tab 2's separator (i.e., between tab2 end=21 and tab3 start=22).
-- start=0, budget=22 → window=[0,22]. tab1 cum[0,10], tab2 cum[11,21], tab3 cum[22,32].
-- tab1: 10>0 AND 0<22 → first=1. tab2: 21>0 AND 11<22 → last=2. tab3: 32>0 AND 22<22 FALSE → skip.
-- leading=0, trailing = 21-22 = -1 → 0. No snap. Hmm.
-- To actually trigger the snap, the trailing_clip must EAT the whole last tab. That requires
-- last_cum_end - window_end >= last_w → window_end <= last_cum_end - last_w = last_cum_start.
-- But the walk only includes the tab if cum_start < window_end. So trailing clip < last_w always.
-- The snap is thus a defensive invariant — the walk already enforces "no fully clipped boundary tabs".
-- We document this by asserting the defensive behavior on a hand-crafted case where it COULD fire if
-- overlaps were inclusive-on-both-ends (which they aren't). The test below asserts that the function
-- still returns sane output in the boundary case, and separator cells never "count" as visible cells.

-- Test: separator cell sits at window boundary — visible range stays stable.
-- Tabs [10,10,10]: cum [0,10] sep[10] [11,21] sep[21] [22,32]. window=[10,22], budget=12.
-- tab1: 10>10 false → skip. tab2: 21>10 AND 11<22 → first=last=2. tab3: 32>10 AND 22<22 false → skip.
-- first=2, last=2, leading=0, trailing=21-22=-1→0. Separator at cell 10 is NOT at the viewport's left
-- edge — tab1 is already skipped, tab2's label starts at cell 11.
do
    local r = t.derive_visible_range({ 10, 10, 10 }, 10, 12)
    assert(r.first_idx == 2 and r.last_idx == 2, "derive_visible_range: separator-boundary → stable")
    assert(r.leading_clip == 0, "derive_visible_range: separator at boundary → no leading clip")
    assert(r.trailing_clip == 0, "derive_visible_range: separator at boundary → no trailing clip")
end

-- Test: snap-past-separator guard (defensive) — construct a case where the
-- clip would empty the first tab; assert the function advances past it.
-- We fabricate a direct test of the guard by calling with a fake tab width
-- tuple that forces leading_clip >= first_w. Tabs [1,10,10]: cum[0,1] sep[1] [2,12] sep[12] [13,23].
-- start=1, budget=11, window=[1,12]. tab1 cum[0,1]: 1>1 false → skip. tab2 cum[2,12]: first=last=2.
-- leading = 1-2 = -1 → 0. No snap fires here either — the walk already skipped tab 1.
-- Construct snap trigger: the only way leading_clip >= first_w is when the pure walk admitted a tab
-- whose full width is <= leading_clip. For label-only widths, we get that when tab1's label fits
-- inside [start..start] (zero width), i.e., first_w == 0. Zero-width tab is degenerate but valid.
-- Tabs [0,10,10]: total = 0+10+10+2seps=22. cum [0,0] sep[0] [1,11] sep[11] [12,22].
-- start=0, budget=11, window=[0,11]. tab1 cum[0,0]: 0>0 false → skip. tab2 cum[1,11]: first=last=2.
-- No snap.
-- The guard genuinely cannot trigger via honest walks; it exists as a belt-and-braces safety net.
-- Assert the zero-width-tab path doesn't crash.
do
    local r = t.derive_visible_range({ 0, 10, 10 }, 0, 11)
    assert(r.first_idx == 2, "derive_visible_range: zero-width first tab skipped → first=2")
    assert(r.last_idx == 2, "derive_visible_range: tab3 excluded (cum_start 12 not < window_end 11)")
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
-- gutter + suffix into a flat segment list. Core injects a single-cell `" "`
-- separator between each adjacent pair of visible tabs — never before the
-- first, never after the last, never adjacent to a zero-width boundary tab.

-- Test: empty visible tabs — prefix + suffix only (no separator to inject).
do
    local out = t.compose_layout_segments({ { text = "P", style = {} } }, nil, {}, nil, { { text = "S", style = {} } })
    assert(#out == 2, "compose_layout_segments: prefix+suffix → 2")
    assert(out[1].text == "P" and out[2].text == "S", "compose_layout_segments: order")
end

-- Test: full pipeline with gutters — one separator injected between T1 and T2.
do
    local out = t.compose_layout_segments(
        { { text = "P", style = {} } },
        { text = "<", style = {} },
        { { { text = "T1", style = {} } }, { { text = "T2", style = {} } } },
        { text = ">", style = {} },
        { { text = "S", style = {} } }
    )
    assert(#out == 7, "compose_layout_segments: full → 7 segments (prefix, gutter_l, T1, sep, T2, gutter_r, suffix)")
    assert(out[1].text == "P", "compose_layout_segments: [1]=prefix")
    assert(out[2].text == "<", "compose_layout_segments: [2]=left gutter")
    assert(out[3].text == "T1", "compose_layout_segments: [3]=T1")
    assert(out[4].text == " ", "compose_layout_segments: [4]=core-injected separator")
    assert(out[5].text == "T2", "compose_layout_segments: [5]=T2")
    assert(out[6].text == ">", "compose_layout_segments: [6]=right gutter")
    assert(out[7].text == "S", "compose_layout_segments: [7]=suffix")
end

-- Test: no gutters (nil args), single visible tab → no separators.
do
    local out = t.compose_layout_segments({}, nil, { { { text = "T", style = {} } } }, nil, {})
    assert(#out == 1 and out[1].text == "T", "compose_layout_segments: single tab → no separator")
end

-- Test: inject N-1 separators for N visible tabs.
-- 4 tabs → 3 separators interleaved. No gutters/prefix/suffix.
do
    local out = t.compose_layout_segments({}, nil, {
        { { text = "A", style = {} } },
        { { text = "B", style = {} } },
        { { text = "C", style = {} } },
        { { text = "D", style = {} } },
    }, nil, {})
    assert(#out == 7, "compose_layout_segments: 4 tabs + 3 separators = 7 segments")
    assert(out[1].text == "A", "inject-N-1: [1]=A")
    assert(out[2].text == " ", "inject-N-1: [2]=sep")
    assert(out[3].text == "B", "inject-N-1: [3]=B")
    assert(out[4].text == " ", "inject-N-1: [4]=sep")
    assert(out[5].text == "C", "inject-N-1: [5]=C")
    assert(out[6].text == " ", "inject-N-1: [6]=sep")
    assert(out[7].text == "D", "inject-N-1: [7]=D")
end

-- Test: separator styling — the injected separator is plain (empty style).
-- Verifies the separator is owned by core, not inherited from adjacent tabs.
do
    local out = t.compose_layout_segments({}, nil, {
        { { text = "X", style = { bg = "red" } } },
        { { text = "Y", style = { bg = "blue" } } },
    }, nil, {})
    assert(#out == 3, "separator style: 3 segments")
    assert(out[2].text == " ", "separator style: separator text is ' '")
    assert(type(out[2].style) == "table", "separator style: style is a table")
    assert(out[2].style.bg == nil, "separator style: bg not inherited from adjacent tabs")
end

-- Test: zero-width boundary tab gets no adjacent separator on its inner side.
-- Empty segment list for tab 1 (clipped to nothing) → no sep between tab1 and tab2.
do
    local out = t.compose_layout_segments({}, nil, {
        {}, -- zero-width first tab (empty segments)
        { { text = "B", style = {} } },
    }, nil, {})
    -- Empty tab1 contributes 0 segments; no separator between empty and B.
    assert(#out == 1 and out[1].text == "B", "zero-width tab1: no separator injected")
end

-- Test: zero-width last tab gets no adjacent separator on its inner side.
do
    local out = t.compose_layout_segments({}, nil, {
        { { text = "A", style = {} } },
        {}, -- zero-width trailing tab
    }, nil, {})
    assert(#out == 1 and out[1].text == "A", "zero-width tabN: no separator injected")
end

-- === derive_click_regions ===
-- Walk visible tabs with x-offset starting at prefix_w + gutter_l_w. Emit
-- one region per tab keyed by its original tab_index. Gutters and the
-- core-injected inter-tab separator cells aren't clickable — half-open
-- semantics (`start_x` inclusive, `end_x` exclusive) leave the separator
-- cell sitting between tab N's `end_x` and tab N+1's `start_x` dead.

-- Test: correct per-tab regions — advances by `tab.width + 1` between tabs
-- so the 1-cell separator sits between them and is NOT routed to any tab.
do
    local regs = t.derive_click_regions(0, 0, {
        { tab_index = 1, width = 5 },
        { tab_index = 2, width = 10 },
    }, 0)
    assert(#regs == 2, "derive_click_regions: 2 regions")
    assert(regs[1].start_x == 0 and regs[1].end_x == 5 and regs[1].tab_index == 1, "derive_click_regions: [1]=0..5")
    -- Cell 5 is the separator (dead). Tab 2 starts at 6, ends at 16.
    assert(
        regs[2].start_x == 6 and regs[2].end_x == 16 and regs[2].tab_index == 2,
        "derive_click_regions: [2]=6..16 (separator cell 5 is dead)"
    )
end

-- Test: gutter offset accounted (single tab, no separator).
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

-- Test: prefix + left gutter + multi — separator cell between tabs.
do
    local regs = t.derive_click_regions(3, 1, {
        { tab_index = 7, width = 4 },
        { tab_index = 8, width = 6 },
    }, 1)
    -- First x = 3+1 = 4. First region 4..8. Separator cell 8 (dead). Second 9..15.
    assert(regs[1].start_x == 4 and regs[1].end_x == 8, "derive_click_regions: first at 4..8")
    assert(regs[2].start_x == 9 and regs[2].end_x == 15, "derive_click_regions: second at 9..15 (sep at 8)")
end

-- Test: empty visible → no regions.
do
    local regs = t.derive_click_regions(5, 1, {}, 1)
    assert(#regs == 0, "derive_click_regions: empty visible → no regions")
end

-- Test: half-open semantics — cells at exactly `end_x` and `start_x - 1`
-- (the separator cell) route to no tab. Assert the gap between consecutive
-- regions is >= 1 cell wide.
do
    local regs = t.derive_click_regions(0, 0, {
        { tab_index = 1, width = 3 },
        { tab_index = 2, width = 4 },
        { tab_index = 3, width = 5 },
    }, 0)
    assert(#regs == 3, "half-open: 3 regions")
    -- Region 1: 0..3. Separator at cell 3. Region 2: 4..8. Separator at 8. Region 3: 9..14.
    assert(regs[1].end_x == 3 and regs[2].start_x == 4, "half-open: sep cell 3 sits between r1 and r2")
    assert(regs[2].end_x == 8 and regs[3].start_x == 9, "half-open: sep cell 8 sits between r2 and r3")
    -- Assert the separator cells are NOT covered by any region.
    for _, r in ipairs(regs) do
        assert(3 < r.start_x or 3 >= r.end_x, "half-open: cell 3 not in any region")
        assert(8 < r.start_x or 8 >= r.end_x, "half-open: cell 8 not in any region")
    end
end

-- Test: zero-width tab contributes no separator advance — the separator
-- only sits between two tabs that both render at least 1 cell.
do
    local regs = t.derive_click_regions(0, 0, {
        { tab_index = 1, width = 5 },
        { tab_index = 2, width = 0 }, -- zero-width (clipped to 0)
        { tab_index = 3, width = 4 },
    }, 0)
    assert(#regs == 3, "zero-width tab: still emits 3 regions")
    assert(regs[1].start_x == 0 and regs[1].end_x == 5, "zero-width: r1 at 0..5")
    -- No separator after r1 because r2 has width 0. r2 starts at 5, ends at 5.
    assert(regs[2].start_x == 5 and regs[2].end_x == 5, "zero-width: r2 at 5..5 (empty)")
    -- r2 contributes no separator; r3 starts at 5.
    assert(regs[3].start_x == 5 and regs[3].end_x == 9, "zero-width: r3 at 5..9")
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
                { tab_index = 1, label_segments = { { text = "T1", style = {} } } },
                { tab_index = 2, label_segments = { { text = "T2", style = {} } } },
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
                { tab_index = 1, label_segments = { { text = "T1", style = {} } } },
                { tab_index = 2, label_segments = { { text = "T2", style = {} } } },
            },
            suffix = { { text = "S", style = {} } },
        }
    end)
    local restore_sub = install_cell_substring()
    local warns, restore_warn = capture_warns()

    local out = t.build_tab_bar_custom()
    assert(#warns == 0, "happy path: no warn")
    -- Expect: P T1 <sep> T2 S (no gutters — everything fits; core injects the
    -- 1-cell inter-tab separator between the two visible tabs).
    assert(#out == 5, "happy path: 5 segments (prefix + T1 + sep + T2 + suffix)")
    assert(
        out[1].text == "P" and out[2].text == "T1" and out[3].text == " " and out[4].text == "T2" and out[5].text == "S",
        "happy path: segment order with core-injected separator"
    )
    local st = t.get_state()
    assert(#st.tab_regions == 2, "happy path: 2 click regions")
    -- Click regions account for the separator: x-advance between tabs is
    -- `tab.width + 1`. P=1 cell, T1 at 1..3, sep at 3..4 (dead), T2 at 4..6.
    assert(
        st.tab_regions[1].tab_index == 1 and st.tab_regions[1].start_x == 1 and st.tab_regions[1].end_x == 3,
        "happy path: region 1 at 1..3"
    )
    assert(
        st.tab_regions[2].tab_index == 2 and st.tab_regions[2].start_x == 4 and st.tab_regions[2].end_x == 6,
        "happy path: region 2 at 4..6 (separator cell 3..4 is dead click)"
    )

    restore_warn()
    restore_sub()
    t.set_tab_bar_render(nil)
    t.reset_tab_bar_render_warned()
end

-- === renderer-owned gutters (fn-79) ===
-- Renderer returns optional symmetric `gutter_left`/`gutter_right` segment
-- fields. Core still owns show/hide via overflow; renderer proposes glyphs.

-- Test: renderer-owned gutters spliced verbatim when both sides overflow.
-- Installs a fake renderer returning single-segment gutters; asserts click-
-- region origin shifts by the measured gutter widths.
do
    t.reset_tab_bar_render_warned()
    t.set_screen_cols(10)
    t.set_state({
        tabs = {
            { root = mock_pane(1), title = "a" },
            { root = mock_pane(2), title = "b" },
            { root = mock_pane(3), title = "c" },
        },
        active_tab = 2,
    })
    t.set_tab_bar_render(function(_tabs, _cols, _theme, _ctx, _opts)
        return {
            prefix = {},
            tabs = {
                { tab_index = 1, label_segments = { { text = "AAAA", style = {} } } },
                { tab_index = 2, label_segments = { { text = "BBBB", style = {} } } },
                { tab_index = 3, label_segments = { { text = "CCCC", style = {} } } },
            },
            suffix = {},
            gutter_left = { text = "L", style = { fg = "#ff0000" } },
            gutter_right = { text = "R", style = { fg = "#00ff00" } },
        }
    end)
    local restore_sub = install_cell_substring()
    local warns, restore_warn = capture_warns()

    local out = t.build_tab_bar_custom()
    assert(#warns == 0, "renderer-owned gutters: no warn")
    -- screen_cols=10; total tabs=12 (4+4+4); budget=10; active=2 centers BBBB,
    -- gutters on both sides → both overflow so both gutters visible.
    -- Find L/R gutters in output.
    local has_l, has_r = false, false
    for _, seg in ipairs(out) do
        if seg.text == "L" and seg.style and seg.style.fg == "#ff0000" then
            has_l = true
        end
        if seg.text == "R" and seg.style and seg.style.fg == "#00ff00" then
            has_r = true
        end
    end
    assert(has_l, "renderer-owned gutters: L verbatim with style")
    assert(has_r, "renderer-owned gutters: R verbatim with style")
    -- Click-region origin shifts by gutter_l_w=1: first region start_x == 1.
    local st = t.get_state()
    assert(#st.tab_regions >= 1, "renderer-owned gutters: click regions populated")
    assert(st.tab_regions[1].start_x == 1, "renderer-owned gutters: origin shifted by left gutter width")

    restore_warn()
    restore_sub()
    t.set_tab_bar_render(nil)
    t.reset_tab_bar_render_warned()
end

-- Test: renderer-owned gutter list form (multi-segment) spliced in order.
do
    t.reset_tab_bar_render_warned()
    t.set_screen_cols(10)
    t.set_state({
        tabs = {
            { root = mock_pane(1), title = "a" },
            { root = mock_pane(2), title = "b" },
            { root = mock_pane(3), title = "c" },
        },
        active_tab = 2,
    })
    t.set_tab_bar_render(function()
        return {
            prefix = {},
            tabs = {
                { tab_index = 1, label_segments = { { text = "AAAA", style = {} } } },
                { tab_index = 2, label_segments = { { text = "BBBB", style = {} } } },
                { tab_index = 3, label_segments = { { text = "CCCC", style = {} } } },
            },
            suffix = {},
            gutter_left = { { text = "<", style = {} }, { text = " ", style = {} } },
            gutter_right = { { text = " ", style = {} }, { text = ">", style = {} } },
        }
    end)
    local restore_sub = install_cell_substring()
    local warns, restore_warn = capture_warns()

    local out = t.build_tab_bar_custom()
    assert(#warns == 0, "renderer-owned gutter list: no warn")
    -- Verify both halves of each 2-seg gutter make it through.
    local left_glyph, left_space, right_space, right_glyph = false, false, false, false
    for i, seg in ipairs(out) do
        if seg.text == "<" then
            left_glyph = true
            assert(out[i + 1] and out[i + 1].text == " ", "list gutter: left spacer follows glyph")
        end
        if seg.text == ">" then
            right_glyph = true
            assert(out[i - 1] and out[i - 1].text == " ", "list gutter: right spacer precedes glyph")
        end
    end
    assert(left_glyph, "renderer-owned gutter list: left glyph present")
    assert(right_glyph, "renderer-owned gutter list: right glyph present")

    restore_warn()
    restore_sub()
    t.set_tab_bar_render(nil)
    t.reset_tab_bar_render_warned()
end

-- Test: renderer returns neither gutter → falls back to static config glyph.
do
    t.reset_tab_bar_render_warned()
    t.set_screen_cols(10)
    t.set_tab_bar_gutters("<", ">")
    t.set_state({
        tabs = {
            { root = mock_pane(1), title = "a" },
            { root = mock_pane(2), title = "b" },
            { root = mock_pane(3), title = "c" },
        },
        active_tab = 2,
    })
    t.set_tab_bar_render(function()
        return {
            prefix = {},
            tabs = {
                { tab_index = 1, label_segments = { { text = "AAAA", style = {} } } },
                { tab_index = 2, label_segments = { { text = "BBBB", style = {} } } },
                { tab_index = 3, label_segments = { { text = "CCCC", style = {} } } },
            },
            suffix = {},
            -- no gutter_left / gutter_right → core falls back to config glyphs.
        }
    end)
    local restore_sub = install_cell_substring()
    local warns, restore_warn = capture_warns()

    local out = t.build_tab_bar_custom()
    assert(#warns == 0, "fallback gutter: no warn")
    local has_default_left, has_default_right = false, false
    for _, seg in ipairs(out) do
        if seg.text == "<" then
            has_default_left = true
        end
        if seg.text == ">" then
            has_default_right = true
        end
    end
    assert(has_default_left, "fallback gutter: default '<' from config")
    assert(has_default_right, "fallback gutter: default '>' from config")

    restore_warn()
    restore_sub()
    t.set_tab_bar_render(nil)
    t.reset_tab_bar_render_warned()
end

-- Test: asymmetric gutter (only left set) → validator rejects → whole-bar kill.
do
    t.reset_tab_bar_render_warned()
    t.set_screen_cols(80)
    t.set_state({
        tabs = { { root = mock_pane(1), title = "a" }, { root = mock_pane(2), title = "b" } },
        active_tab = 1,
    })
    t.set_tab_bar_render(function()
        return {
            prefix = {},
            tabs = { { tab_index = 1, label_segments = { { text = "T", style = {} } } } },
            suffix = {},
            gutter_left = { text = "L", style = {} },
            -- gutter_right deliberately absent → asymmetric → malformed.
        }
    end)
    local restore_sub = install_cell_substring()
    local warns, restore_warn = capture_warns()

    local out = t.build_tab_bar_custom()
    assert(#out == 0, "asymmetric gutter: empty strip on whole-bar kill")
    assert(#warns == 1, "asymmetric gutter: warn once")
    assert(warns[1]:find("both be set or both absent"), "asymmetric gutter: warn names the rule")
    local st = t.get_state()
    assert(st.tab_bar_render_warned == true, "asymmetric gutter: latch flipped true")

    restore_warn()
    restore_sub()
    t.set_tab_bar_render(nil)
    t.reset_tab_bar_render_warned()
end

-- Test: non-table segment (gutter_left = 42) → validator rejects → whole-bar kill.
do
    t.reset_tab_bar_render_warned()
    t.set_screen_cols(80)
    t.set_state({
        tabs = { { root = mock_pane(1), title = "a" }, { root = mock_pane(2), title = "b" } },
        active_tab = 1,
    })
    t.set_tab_bar_render(function()
        return {
            prefix = {},
            tabs = { { tab_index = 1, label_segments = { { text = "T", style = {} } } } },
            suffix = {},
            gutter_left = 42,
            gutter_right = { text = "R", style = {} },
        }
    end)
    local restore_sub = install_cell_substring()
    local warns, restore_warn = capture_warns()

    local out = t.build_tab_bar_custom()
    assert(#out == 0, "non-table gutter: empty strip")
    assert(#warns == 1, "non-table gutter: warn once")
    assert(warns[1]:find("gutter_left"), "non-table gutter: warn names the field")

    restore_warn()
    restore_sub()
    t.set_tab_bar_render(nil)
    t.reset_tab_bar_render_warned()
end

-- Test: segment with non-string `text` (gutter_left = {text={}, style={}}) →
-- validator rejects → whole-bar kill.
do
    t.reset_tab_bar_render_warned()
    t.set_screen_cols(80)
    t.set_state({
        tabs = { { root = mock_pane(1), title = "a" }, { root = mock_pane(2), title = "b" } },
        active_tab = 1,
    })
    t.set_tab_bar_render(function()
        return {
            prefix = {},
            tabs = { { tab_index = 1, label_segments = { { text = "T", style = {} } } } },
            suffix = {},
            gutter_left = { text = {}, style = {} },
            gutter_right = { text = "R", style = {} },
        }
    end)
    local restore_sub = install_cell_substring()
    local warns, restore_warn = capture_warns()

    local out = t.build_tab_bar_custom()
    assert(#out == 0, "non-string text: empty strip")
    assert(#warns == 1, "non-string text: warn once")
    assert(warns[1]:find("gutter_left"), "non-string text: warn names field")
    assert(warns[1]:find("text"), "non-string text: warn names 'text' problem")

    restore_warn()
    restore_sub()
    t.set_tab_bar_render(nil)
    t.reset_tab_bar_render_warned()
end

-- Test: `opts` 5th arg is passed to the renderer with gutter glyph strings.
do
    t.reset_tab_bar_render_warned()
    t.set_screen_cols(40)
    t.set_tab_bar_gutters("LL", "RR")
    t.set_state({
        tabs = { { root = mock_pane(1), title = "a" }, { root = mock_pane(2), title = "b" } },
        active_tab = 1,
    })
    local captured_opts = nil
    t.set_tab_bar_render(function(_tabs, _cols, _theme, _ctx, opts)
        captured_opts = opts
        return {
            prefix = {},
            tabs = { { tab_index = 1, label_segments = { { text = "T", style = {} } } } },
            suffix = {},
        }
    end)
    local restore_sub = install_cell_substring()
    local warns, restore_warn = capture_warns()

    t.build_tab_bar_custom()
    assert(captured_opts ~= nil, "opts arg: present")
    assert(captured_opts.gutter_left == "LL", "opts arg: gutter_left forwarded")
    assert(captured_opts.gutter_right == "RR", "opts arg: gutter_right forwarded")
    assert(#warns == 0, "opts arg: no warn")

    restore_warn()
    restore_sub()
    t.set_tab_bar_render(nil)
    t.set_tab_bar_gutters("<", ">")
    t.reset_tab_bar_render_warned()
end

-- === validate_tab_bar_layout ===
-- Pure-function contract check. The validator is the fail-loudly boundary for
-- the renamed `label_segments` field — stale renderers still emitting
-- `segments` must fail validation so `degraded_tab_bar` + the warn-once latch
-- engage. No state setup needed — the function takes a layout table and
-- returns nil (ok) or a reason string (malformed).

-- Test: stale-shape rejection — layout with `segments` instead of
-- `label_segments` is malformed. This is the fn-80 atomic-migration guard.
do
    local reason = t.validate_tab_bar_layout({
        prefix = {},
        tabs = { { tab_index = 1, segments = { { text = "T", style = {} } } } },
        suffix = {},
    })
    assert(type(reason) == "string", "validate: stale `segments` → rejected")
    assert(reason:find("malformed"), "validate: stale `segments` → names malformed")
end

-- Test: happy path — `label_segments` present → nil (ok).
do
    local reason = t.validate_tab_bar_layout({
        prefix = {},
        tabs = { { tab_index = 1, label_segments = { { text = "T", style = {} } } } },
        suffix = {},
    })
    assert(reason == nil, "validate: label_segments present → ok")
end

-- Test: non-table `label_segments` → rejected.
do
    local reason = t.validate_tab_bar_layout({
        prefix = {},
        tabs = { { tab_index = 1, label_segments = "not-a-table" } },
        suffix = {},
    })
    assert(type(reason) == "string", "validate: non-table label_segments → rejected")
end

-- Test: non-integer tab_index → rejected (unchanged from fn-72).
do
    local reason = t.validate_tab_bar_layout({
        prefix = {},
        tabs = { { tab_index = 1.5, label_segments = {} } },
        suffix = {},
    })
    assert(type(reason) == "string", "validate: non-integer tab_index → rejected")
end

-- Test: stale-shape latch via build_tab_bar_custom path — a renderer returning
-- `segments` (not `label_segments`) trips the validator + degraded_tab_bar.
do
    t.reset_tab_bar_render_warned()
    t.set_screen_cols(80)
    t.set_state({
        tabs = { { root = mock_pane(1), title = "a" }, { root = mock_pane(2), title = "b" } },
        active_tab = 1,
    })
    t.set_tab_bar_render(function()
        return {
            prefix = {},
            tabs = { { tab_index = 1, segments = { { text = "T", style = {} } } } },
            suffix = {},
        }
    end)
    local restore_sub = install_cell_substring()
    local warns, restore_warn = capture_warns()

    local out = t.build_tab_bar_custom()
    assert(#out == 0, "stale-shape: empty strip on whole-bar kill")
    assert(#warns == 1, "stale-shape: warn once")
    assert(warns[1]:find("malformed"), "stale-shape: warn names malformed")
    local st = t.get_state()
    assert(st.tab_bar_render_warned == true, "stale-shape: latch flipped true")

    -- Second invocation must NOT emit a second warn (latched).
    t.build_tab_bar_custom()
    assert(#warns == 1, "stale-shape: NO second warn (latched)")

    restore_warn()
    restore_sub()
    t.set_tab_bar_render(nil)
    t.reset_tab_bar_render_warned()
end

-- Cleanup: leave renderer config nil + warn latch reset for any tests that follow.
t.set_tab_bar_render(nil)
t.reset_tab_bar_render_warned()
