# NAME

prise - configuration file

# SYNOPSIS

*~/.config/prise/init.lua*

# DESCRIPTION

Prise is configured through a Lua file at **~/.config/prise/init.lua**. This
file must return a UI table that implements the prise UI interface.

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
:   Optional custom renderer function. It receives **(tabs, screen_width,
    theme)** and must return an array of segments compatible with
    **prise.Text()**.

**format_title**
:   Optional function that formats automatically-derived tab titles before they
    are passed to the renderer. Explicitly renamed tab titles are not reformatted.

When **render** is provided, each tab entry includes:

- **index** - 1-based tab index
- **title** - Display title for the tab
- **is_explicit_title** - True when the title was set explicitly
- **is_active** - True for the active tab
- **is_hovered** - True when the pointer is hovering over the tab
- **is_close_hovered** - True when the pointer is hovering over the tab close button
- **pane_count** - Number of panes in the tab
- **is_zoomed** - True when the tab currently has a zoomed pane

Returned segments may include **tab_index** to mark which tab they belong to.
This lets hover and click regions match the rendered tab structure exactly.

Example:

```lua
ui.setup({
    tab_bar = {
        render = function(tabs, screen_width, theme)
            local segments = {}
            for _, tab in ipairs(tabs) do
                local label = string.format(" %d:%s (%d) ", tab.index, tab.title, tab.pane_count)
                table.insert(segments, {
                    text = label,
                    tab_index = tab.index,
                    style = {
                        bg = tab.is_active and theme.bg4 or theme.bg2,
                        fg = theme.fg_bright,
                        bold = tab.is_zoomed,
                    },
                })
            end
            return segments
        end,
    },
})
```

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

# FLOATING PANE

The **floating** table configures the floating terminal pane.

**width**
:   Width in columns. Default: **100**

**height**
:   Height in rows. Default: **30**

Example:

```lua
ui.setup({
    floating = {
        width = 120,
        height = 40,
    },
})
```

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
:   Target session name. If the current session differs, the UI switches first.

**tab**
:   Set to **"new"** to open the PTY in a new tab.

**title**
:   Explicit title for the tab containing the new PTY.

When any placement field is present, the tiling UI handles the **pty_spawned**
event automatically: switching sessions, creating tabs, and renaming as needed.

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

## Floating Pane

**floating_toggle**
:   Toggle the floating terminal pane

**floating_increase_size**
:   Increase floating pane size

**floating_decrease_size**
:   Decrease floating pane size

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
:   Increase floating pane size

**-**
:   Decrease floating pane size

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

# SEE ALSO

[prise(1)](prise.1.html), [prise(7)](prise.7.html)
