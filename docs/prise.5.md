# NAME

prise - configuration file

# SYNOPSIS

*~/.config/prise/init.lua*

*~/.config/prise/prise.toml*

# DESCRIPTION

Prise is configured through two files. The Lua file at
**~/.config/prise/init.lua** must return a UI table that implements the prise
UI interface. The optional TOML file at **~/.config/prise/prise.toml** declares
plug processes that the server should spawn and supervise at startup; see
**PLUGS** below.

If no configuration file is present, prise uses the default tiling UI.

The simplest configuration uses the built-in tiling UI:

```lua
return require("prise").tiling()
```

# SETUP OPTIONS

The tiling UI can be customized by calling **setup()** before returning:

```lua
local ui = require("prise").tiling()

ui.setup({
    theme = { ... },
    status_bar = { ... },
    tab_bar = { ... },
    floating = { ... },
    keybinds = { ... },
    layouts = { ... },
    default_layout = "...",
    keep_attached = true,
})

return ui
```

# THEME

The **theme** table configures colors. All values are hex color strings.

**mode_normal**
:   Color for normal mode indicator in status bar. Default: **#89b4fa**

**mode_command**
:   Color for command mode indicator. Default: **#f38ba8**

**bg1**
:   Darkest background. Default: **#1e1e2e**

**bg2**
:   Dark background. Default: **#313244**

**bg3**
:   Medium background. Default: **#45475a**

**bg4**
:   Lighter background. Default: **#585b70**

**fg_bright**
:   Main text color. Default: **#cdd6f4**

**fg_dim**
:   Secondary text color. Default: **#a6adc8**

**fg_dark**
:   Dark text (on light backgrounds). Default: **#1e1e2e**

**accent**
:   Accent color. Default: **#89b4fa**

**green**
:   Success/connected color. Default: **#a6e3a1**

**yellow**
:   Warning color. Default: **#f9e2af**

Example:

```lua
ui.setup({
    theme = {
        accent = "#ff79c6",
        mode_normal = "#50fa7b",
    },
})
```

# BORDERS

The **borders** table configures pane borders for visual separation.

**enabled**
:   Enable or disable pane borders globally. Default: **false**

**show_single_pane**
:   Show border when only one pane exists. Default: **false**

**mode**
:   Border rendering mode. Options: **"box"**, **"separator"**. Default: **"box"**

**style**
:   Border drawing style. Options: **"none"**, **"single"**, **"double"**, **"rounded"**. Default: **"single"**

**focused_color**
:   Hex color code for the focused pane's border. Default: **#89b4fa**

**unfocused_color**
:   Hex color code for unfocused pane borders. Default: **#585b70**

Available border modes:

- **"box"** - Full borders around each pane (default)
- **"separator"** - Tmux-style borders drawn only between panes

Available border styles:

- **"single"** - Single-line borders: `┌─┐│└┘`
- **"double"** - Double-line borders: `╔═╗║╚╝`
- **"rounded"** - Rounded corners: `╭─╮│╰╯`
- **"none"** - Invisible borders (for consistent spacing)

Example:

```lua
ui.setup({
    borders = {
        enabled = true,
        mode = "box",                       -- or "separator" for tmux-style
        show_single_pane = false,           -- Hide border for single pane
        style = "rounded",
        focused_color = "#f38ba8",          -- Pink
        unfocused_color = "#313244",        -- Dark gray
    },
})
```

# STATUS BAR

The **status_bar** table configures the bottom status bar.

**enabled**
:   Show the status bar. Default: **true**

Example:

```lua
ui.setup({
    status_bar = { enabled = false },
})
```

# TAB BAR

The **tab_bar** table configures the tab bar.

**show_single_tab**
:   Show the tab bar even with only one tab. Default: **false**

**render**
:   Optional custom tab bar renderer. Overrides the default design.
    Signature: `function(tabs, screen_width, theme, ctx, opts) -> TabBarLayout`.
    Returns a structured layout with three required slots plus two
    optional renderer-owned gutter fields:

    **prefix**
    :   List of styled segments drawn at the left edge. Never clipped.
        Core reserves this width before measuring tabs — use it for
        session headers, mode indicators, or any fixed-position content
        that must always be visible.

    **tabs**
    :   List of `{tab_index = N, label_segments = {...}}` entries, one
        per tab. `tab_index` is the tab's index in the full unsliced
        `tabs` input and drives click-region mapping. `label_segments`
        carries the tab's label segments only — the inter-tab separator
        is a 1-cell space injected by the core compositor between
        adjacent visible tabs and is not part of a tab's segment list
        or clippable width. Core applies centered-focus windowing (tmux
        `format_draw_put_list`-style) to this slot: the active tab stays
        visually centered when space permits, with cell-precise clipping
        of boundary tabs that only partially fit.

    **suffix**
    :   List of styled segments drawn at the right edge. Never clipped.
        May be empty. Reserved width mirrors **prefix**: use for status
        segments, clocks, or other right-anchored content.

    **gutter_left**, **gutter_right** (optional)
    :   When the renderer wants to own the gutter glyph, spacing, and
        theming, return both fields — each is either a single
        `{text = string, style = table?}` segment or a list of such
        segments. The two fields are all-or-nothing: returning one
        without the other is malformed and triggers the whole-bar kill
        path. Core still owns show/hide: whichever side's tabs fit
        receives no gutter; whichever side overflows gets the renderer's
        segment(s) spliced verbatim. When both fields are absent, core
        falls back to the plain-string `gutter_left` / `gutter_right`
        config glyphs.

    The `ctx` argument is reserved for future fields and is currently
    empty. `opts` is a filtered table carrying only
    `{gutter_left, gutter_right}` — the plain-string glyph values from
    `tab_bar` config — so renderers can author themed gutter segments
    from the same source of truth as the fallback path. `tabs` is always
    the full unsliced list — core handles windowing from the returned
    `TabBarLayout`. Width math must use `prise.gwidth`; `#str` miscounts
    wide graphemes. On renderer error (non-table return, missing slot,
    malformed gutter field, pcall failure) the tab strip draws empty for
    the frame and a single warn is logged via `prise.log.warn`
    (subsequent failures are silent — log hygiene at 60fps).

**measure**
:   Required when a custom **render** is set and the tab strip may overflow.
    Signature: `function(tab) -> cells` — returns the integer label-only
    cell-width the renderer will draw for the given tab (tabs slot only;
    **prefix** and **suffix** widths are measured directly from their
    returned segments). Must NOT include the inter-tab separator — core
    injects a 1-cell space between adjacent visible tabs and accounts for
    it internally. Core calls this once per tab per frame to compute the
    centered-focus window: the active tab stays centered when possible;
    boundary tabs clip cell-precise against the available budget. Width
    math must use `prise.gwidth`; `#str` miscounts wide graphemes.
    Returning `0` marks the tab as zero-width (windowing skips over it).
    If **measure** is absent when **render** is set, a warn is logged and
    the tab strip draws empty — existing renderers must return
    `TabBarLayout` and provide **measure**.

**gutter_left**
:   Plain-string glyph rendered at the left edge when one or more tabs
    are hidden off the left side of the viewport. Only appears when tabs
    are actually hidden — never shown when the full strip fits.
    Signature: `string`. Default: **"<"**. Cell-width is measured via
    `prise.gwidth`, so multi-cell glyphs work correctly. Used by the
    built-in renderer and as the fallback when a custom **render**
    returns no gutter fields; custom renderers that want themed gutter
    segments should return them via `TabBarLayout.gutter_left` /
    `gutter_right` instead.

**gutter_right**
:   Plain-string glyph rendered at the right edge when one or more tabs
    are hidden off the right side of the viewport. Mirrors **gutter_left**:
    only appears when tabs are actually hidden. Signature: `string`.
    Default: **">"**.

**format_title**
:   Optional `function(title, tab_index) -> string` applied to auto-derived
    tab titles (not explicit renamed titles). Default: no formatting.

# LAYOUTS

The **layouts** table defines named layout presets for tabs and panes.

Each layout has:

**tabs**
:   List of tabs. Each tab needs a **root** node and can set **title** or **floating**.

**root**
:   A pane or split definition.

**pane**
:   `{ type = "pane", cwd = "...", cmd = "...", ratio = 0.5 }`

The **cmd** field can also be passed as a spawn option. The command is written
to the PTY master immediately at spawn time. The kernel queues the bytes in
the line discipline buffer; the shell consumes them on its first read.

**split**
:   `{ type = "split", direction = "horizontal"|"vertical", children = { ... } }`

Ratios live on children, not on the split node. A child with no ratio gets an equal share of remaining space (Pass 3). A child with `ratio = r` is sized at `r * available` (Pass 2). For an asymmetric 70/30 split: set `ratio = 0.7` on `children[1]` and `ratio = 0.3` on `children[2]`. For an equal split, omit ratio on all children.

**floating**
:   Optional floating pane for a tab. `{ pane = { ... }, visible = true, width = 120, height = 40 }`

**default_layout**
:   Name of a layout to apply on startup when no session exists.

Example:

```lua
ui.setup({
    layouts = {
        work = {
            name = "work",
            tabs = {
                {
                    title = "editor",
                    root = {
                        type = "split",
                        direction = "horizontal",
                        children = {
                            { type = "pane", cwd = "~/code" },
                            { type = "pane", cmd = "git status" },
                        },
                    },
                    floating = {
                        pane = { type = "pane", cmd = "htop" },
                        visible = false,
                    },
                },
            },
        },
    },
    default_layout = "work",
})
```

# OVERLAYS

Overlays are named terminal panes that float above the tiling layout. Each
overlay is toggled independently, has its own keybind, and spawns a configured
command on first open. The classic **floating** pane is the built-in overlay
named `floating` — setting `ui.setup({ floating = { ... } })` just configures
that one.

## Overlay config fields

**key**
:   Keybind to toggle this overlay (e.g. `"<leader>g"`). Auto-registered.

**cmd**
:   Command to run. By default wrapped in `exec` so the overlay auto-dismisses
    when the command exits. Must be an external binary — shell builtins and
    compound statements need `shell = true`.

**argv**
:   Direct argv for exec, bypassing the login shell. Eliminates the
    shell-prompt flash during overlay startup. Mutually exclusive with **cmd**.

**shell**
:   If true, spawn a persistent login shell with **cmd** typed into it. The
    overlay stays up after **cmd** exits until the shell itself exits.
    Default **false**.

**width**
:   Width in columns (number) or a percentage string like **"60%"** that
    tracks `screen_cols` on terminal resize. Percentages must be integers
    between **10** and **100**. Default: **"60%"**.

**height**
:   Height in rows (number) or a percentage string like **"70%"** that
    tracks `screen_rows`. Same bounds as **width**. Default: **"70%"**.

**anchor**
:   Position anchor. Default **"center"**.

**x**, **y**
:   Explicit position offsets (cells).

**border**, **border_color**
:   Per-overlay border style and color overrides.

Percentage sizes are clamped to the absolute bounds of the overlay resize
range (width 40–200 cells, height 10–50 cells), so `"100%"` on an oversized
terminal still produces a readable overlay rather than covering the whole
screen.

## Example

```lua
ui.setup({
    overlays = {
        -- Classic floating terminal, half the screen
        floating = {
            key = "<leader>f",
            width = "50%",
            height = "50%",
        },
        -- Lazygit as an overlay, fullscreen-ish
        lazygit = {
            key = "<leader>g",
            cmd = "lazygit",
            width = "90%",
            height = "90%",
        },
        -- htop in a fixed 120x40 cell box
        procs = {
            key = "<leader>h",
            cmd = "htop",
            width = 120,
            height = 40,
        },
    },
})
```

For backwards compatibility, `ui.setup({ floating = { width = ..., height = ... } })`
continues to work — it's translated into the `floating` overlay entry. The
**floating** table also accepts percentage strings.

## Resizing

Two action pairs nudge overlay dimensions interactively:

- **floating_increase_size** / **floating_decrease_size** step the overlay by
  5 columns × 2 rows. Using these drops percent-tracking: the overlay
  becomes cell-mode and stops following terminal resizes.
- **floating_increase_pct** / **floating_decrease_pct** step the overlay's
  percentage by 5%. Using these on a cell-mode overlay upconverts it by
  computing its current percentage of the screen and stepping from there.

# MACOS OPTION KEY

**macos_option_as_alt**
:   Controls how the macOS Option key behaves. Options: **"false"**, **"left"**, **"right"**, **"true"**. Default: **"false"**

When set to **"false"**, Option produces special characters (e.g., Option+e for é).
When set to **"left"**, **"right"**, or **"true"**, the corresponding Option key(s)
act as Alt for keybindings and terminal applications.

Example:

```lua
ui.setup({
    macos_option_as_alt = "true",
})
```

# KEEP ATTACHED

**keep_attached**
:   When the last pane in the last tab exits, switch to another session instead
    of exiting. When no other sessions exist, prise exits normally. Default:
    **true**

NOTE: when switching via **keep_attached**, the departing session's state file
is removed before the switch; it is not saved to disk. Without this the save
branch of the session-switch path would re-create the file in between the
last pane's exit and the async pty_exited notification, leaving an empty
phantom session that shows up in **list_sessions** and the session picker.

Example:

```lua
ui.setup({
    keep_attached = false,  -- Exit when last pane closes
})
```

# LEADER KEY

**leader**
:   The leader key sequence used as a prefix for keybindings. Uses vim-style
    notation (see Key Notation below). Default: **"<D-k>"** (Super+k)

Example:

```lua
ui.setup({
    leader = "<C-a>",  -- Use Ctrl+a as leader
})
```

# CUSTOM KEYBINDS

The **keybinds** table maps vim-style key strings to either built-in actions
or custom Lua functions.

Each entry maps a key string to:

- A **string**: The name of a built-in action (e.g., "split_horizontal")
- A **function**: A custom Lua function to execute

Key strings use vim-style notation with angle brackets for modifiers and
special keys. Plain characters can be written directly.

## Modifiers

- **<C-x>** - Ctrl+x
- **<A-x>** - Alt+x
- **<S-x>** - Shift+x
- **<D-x>** - Super/Cmd+x
- **<leader>** - Expands to the configured leader key

Modifiers can be combined: **<C-A-x>** for Ctrl+Alt+x, **<C-S-D-a>** for
Ctrl+Shift+Super+a.

## Special Keys

- **<Enter>**, **<Return>**, **<CR>** - Enter key
- **<Tab>** - Tab key
- **<Esc>**, **<Escape>** - Escape key
- **<Space>** - Space bar
- **<BS>**, **<Backspace>** - Backspace key
- **<Del>**, **<Delete>** - Delete key
- **<Up>**, **<Down>**, **<Left>**, **<Right>** - Arrow keys
- **<Home>**, **<End>** - Home/End keys
- **<PageUp>**, **<PageDown>** - Page Up/Down keys
- **<Insert>** - Insert key
- **<F1>** through **<F12>** - Function keys

## Examples

- **a** - The letter "a"
- **<C-a>** - Ctrl+a
- **<D-k>v** - Super+k followed by v
- **<leader>s** - Leader followed by s
- **<C-S-Tab>** - Ctrl+Shift+Tab

Example:

```lua
local prise = require("prise")
local ui = prise.tiling()

ui.setup({
    leader = "<C-a>",  -- Use Ctrl+a as leader
    keybinds = {
        -- Built-in action
        ["<leader>v"] = "split_horizontal",

        -- Custom function
        ["<leader>g"] = function()
            prise.log.info("Custom keybind executed!")
        end,
    },
})

return ui
```

# SPAWN PLACEMENT

The **spawn_pty** RPC accepts optional placement fields that control where a
new PTY appears in the tiling UI:

**session**
:   Target session name. The PTY is placed in the target session's saved-state
    file (created if absent). The viewer is NOT switched — programmatic spawns
    do not steal focus.

**tab**
:   Set to **"new"** to open the PTY in a new tab.

**title**
:   Explicit title for the tab containing the new PTY.

**focus**
:   Boolean, default **false**. Only honored on same-session spawns. When
    **true** and the **tab** field matches an existing tab title, the UI
    switches the active tab to the spawned PTY's tab. When unset or false,
    the PTY is attached without changing which tab the human is viewing.

When any placement field is present, the tiling UI handles the **pty_spawned**
event automatically: creating tabs and renaming as needed. Cross-session
placement is silent — the viewer never changes — so callers driving spawns
from outside the human's current session can do so without disrupting focus.

# TILING UI HELPERS

**ui.get_theme()**
:   Return the resolved theme table with defaults merged with user overrides
    from **setup()**. Keys match the properties listed in the THEME section.

# BUILT-IN ACTIONS

The following actions can be used as values in the **keybinds** table.

## Pane Management

**split_horizontal**
:   Split the current pane horizontally (side by side)

**split_vertical**
:   Split the current pane vertically (stacked)

**split_auto**
:   Split automatically based on pane dimensions (horizontal if wide, vertical if tall)

Splitting a zoomed pane exits zoom first so the new pane is visible immediately.

**close_pane**
:   Close the current pane

**toggle_zoom**
:   Toggle zoom on the current pane (maximize/restore)

Zoom state is remembered per tab and restored when you switch back to that tab.

**break_pane**
:   Break the focused pane out of its tab into a new tab in the same session. No-op when focused pane is alone in its tab. Same-session only.

## Focus Navigation

**focus_left**
:   Move focus to the pane on the left

**focus_right**
:   Move focus to the pane on the right

**focus_up**
:   Move focus to the pane above

**focus_down**
:   Move focus to the pane below

## Pane Resizing

**resize_left**
:   Shrink the current pane horizontally

**resize_right**
:   Grow the current pane horizontally

**resize_up**
:   Shrink the current pane vertically

**resize_down**
:   Grow the current pane vertically

## Tab Management

**new_tab**
:   Create a new tab

**close_tab**
:   Close the current tab

**rename_tab**
:   Rename the current tab

**next_tab**
:   Switch to the next tab

**previous_tab**
:   Switch to the previous tab

**tab_1** through **tab_10**
:   Switch to tab by number

## Session Management

**detach_session**
:   Detach from the current session

**rename_session**
:   Rename the current session

**quit**
:   Quit prise (same as detach)

## Other

**layout_picker**
:   Open the layout picker

**command_palette**
:   Open the command palette

## Overlays

**floating_toggle**
:   Toggle the floating terminal pane (the built-in `floating` overlay).
    Custom overlays registered via `ui.setup({ overlays = ... })` get their
    own keybind-bound action automatically.

**floating_increase_size**
:   Step the active overlay by +5 columns × +2 rows (absolute cell mode).
    Drops percent-tracking if active.

**floating_decrease_size**
:   Step the active overlay by -5 columns × -2 rows (absolute cell mode).
    Drops percent-tracking if active.

**floating_increase_pct**
:   Step the active overlay's width and height percentages by +5 each.
    Upconverts a cell-mode overlay to percent-mode by computing the current
    percentage of the screen.

**floating_decrease_pct**
:   Step the active overlay's width and height percentages by -5 each.
    Same upconvert behavior as **floating_increase_pct**.

# DEFAULT KEYBINDS

The tiling UI uses a leader key sequence. Press the leader key (default:
**Super+k**), then one of:

**v**
:   Split horizontal

**s**
:   Split vertical

**Enter**
:   Split auto (horizontal if wide, vertical if tall)

**h**, **j**, **k**, **l**
:   Focus left, down, up, right

**H**, **J**, **K**, **L**
:   Resize pane left, down, up, right

**w**
:   Close pane

**z**
:   Toggle zoom (maximize current pane)

**t**
:   New tab

**c**
:   Close tab

**n**, **p**
:   Next/previous tab

**1-9**
:   Switch to tab by number

**r**
:   Rename current tab

**d**
:   Detach from session

**q**
:   Quit prise

**0**
:   Switch to tab 10

**f**
:   Toggle floating pane

**o**
:   Open layout picker

**+**
:   Increase floating pane size (absolute cells)

**-**
:   Decrease floating pane size (absolute cells)

**)**
:   Increase floating pane size (percent of screen)

**(**
:   Decrease floating pane size (percent of screen)

The command palette (**Super+p**) provides fuzzy search for all commands.

# TILING UI HELPERS

The built-in tiling UI exposes helper methods that user configuration code can
call directly.

**ui.get_active_tab_info()**
:   Return information about the active tab as a table with **index**,
    **title**, and **pane_count**, or **nil** when no tab is active. The pane
    count includes floating panes.

**ui.get_focused_pane_index()**
:   Return the 1-based index of the focused pane within the active tab, or
    **nil** when no pane is focused.

**ui.get_focused_id()**
:   Return the raw pty_id of the focused pane, or **nil** when no pane is
    focused. Complements **get_focused_pane_index** for callers that need
    to reference the focused pane by its actual identifier rather than by
    position within a tab.

**ui.send_key_to_focused(data)**
:   Send a key event to the focused pane, or to the visible floating pane when
    one is open.

The **data** table uses the same fields as PTY key events:

- **key** - Key text to send
- **code** - Optional key code name
- **ctrl**, **alt**, **shift**, **super** - Optional modifier flags
- **release** - Optional key release flag

**ui.send_mouse_to_focused(data)**
:   Send a mouse event to the focused pane, or to the visible floating pane
    when one is open.

The **data** table uses the same fields as PTY mouse events:

- **col**, **row** - Optional pane-relative coordinates
- **button** - Optional mouse button name
- **action** - Optional mouse action such as press, release, or move
- **ctrl**, **alt**, **shift** - Optional modifier flags

**ui.execute_action(name)**
:   Execute a built-in action by its string name. This is useful when custom
    Lua code needs to trigger the same action handlers used by keybinds and the
    command palette.

Example:

```lua
local ui = require("prise").tiling()

local tab = ui.get_active_tab_info()
if tab then
    local pane_idx = ui.get_focused_pane_index()
    local pane_id = ui.get_focused_id()
    print(string.format("Tab %d: %s (pane %d/%d, pty=%s)",
        tab.index, tab.title, pane_idx or 0, tab.pane_count,
        tostring(pane_id)))
end

ui.execute_action("close_tab")
```

# PLUGS

The optional **~/.config/prise/prise.toml** file declares plug processes that
the server should spawn and supervise at startup. Each plug is described by a
**[[plug]]** array-of-tables block. The server reads the file once during
startup, before it begins accepting client connections, and registers each
declared plug with its existing managed-plug machinery (the same machinery used
by the **spawn_plug** RPC).

Each **[[plug]]** block accepts the following keys:

**name**
:   Plug name. String. Required. Maximum 64 bytes. Must not contain slashes
    or whitespace. Names must be unique across all blocks.

**cmd**
:   Command to execute. Array of strings. Required. The first element must
    be an absolute path; **PATH** lookup is intentionally not performed
    because the server inherits a minimal environment under launchd. Maximum
    64 elements.

**restart**
:   Whether to respawn the plug if it exits. Boolean. Optional. Default
    **false**.

**restart_delay_ms**
:   Delay in milliseconds before the server respawns a crashed plug.
    Integer. Optional. Default **1000**. Must be non-negative.

Example:

```toml
[[plug]]
name = "control-plug"
cmd = ["/usr/local/bin/control-plug"]
restart = true
restart_delay_ms = 500
```

## Startup semantics

The server reads **prise.toml** after binding the listening socket and before
enqueuing the accept task. If the file does not exist, the server starts with
no config-declared plugs. Any other read or parse error — malformed TOML,
unknown keys inside a **[[plug]]** block, non-absolute **cmd[0]**, empty
**cmd**, duplicate **name**, oversized **name** — is fatal: the server logs a
**FATAL** message naming the file and the error and exits with non-zero
status. Under launchd the **ThrottleInterval** (10s default) acts as the
circuit breaker against tight crash loops.

A **[[plug]]** block whose binary cannot be spawned (for example, because the
absolute path does not exist) does not take the server down. The server
emits a single **WARN** line of the form:

```
plug spawn failed name=<name> cmd0=<cmd[0]> error=<error_name>
```

and continues to the next block. The server stays up.

## Crash respawn

When a config-declared plug crashes, the server applies the same restart
policy used by the **spawn_plug** RPC: if **restart** is true, the server
waits **restart_delay_ms** and respawns the plug, regenerating the
**PRISE_PLUG_TOKEN**. Restart attempts are unbounded.

## RPC interaction

A plug name declared in **prise.toml** is owned by the server. Any
**spawn_plug** RPC against a config-owned name is rejected with
**PlugConfigOwned**. The TOML declaration is the single source of truth for
that name's command, restart policy, and lifecycle.

# SEE ALSO

[prise(1)](prise.1.html), [prise(7)](prise.7.html)
