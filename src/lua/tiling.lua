local prise = require("prise")
local utils = require("utils")

---@class Pane
---@field type "pane"
---@field id number
---@field pty Pty
---@field ratio? number

---@class Split
---@field type "split"
---@field split_id number
---@field direction "row"|"col"
---@field ratio? number
---@field children (Pane|Split)[]

---@alias Node Pane|Split

---@class Tab
---@field id integer
---@field title? string
---@field root? Node
---@field last_focused_id? number
---@field zoomed_pane_id? number Saved zoom state for inactive tabs
---@field floating? FloatingPane Floating pane for this tab (if any)

---@class FloatingPane
---@field pane Pane The actual pane
---@field visible boolean Whether the floating pane is visible

---@class TabOverlay
---@field pane Pane The pane with PTY
---@field visible boolean Whether currently shown

---@class OverlayConfig
---@field key string Keybind to toggle
---@field cmd? string Command to run. By default, wrapped in `exec` so the
---                    overlay auto-dismisses when the command exits. Must be
---                    an external binary — shell builtins and compound
---                    statements need `shell = true` instead.
---@field shell? boolean If true, spawn a persistent login shell with cmd
---                       typed into it. The overlay stays up after cmd
---                       exits until the shell itself exits. Default false.
---@field width? number Width in columns (default 100)
---@field height? number Height in rows (default 30)
---@field anchor? string Position anchor (default "center")
---@field x? number Explicit x offset
---@field y? number Explicit y offset
---@field border? string Border style
---@field border_color? string Border color

---@class OverlayState
---@field width number Current width (may differ from config after resize)
---@field height number Current height
---@field pending boolean Waiting for PTY to attach

---@class PaletteRegion
---@field start_y number
---@field end_y number
---@field index number

---@class PaletteState
---@field visible boolean
---@field input? TextInput
---@field selected number
---@field scroll_offset number
---@field regions PaletteRegion[]
---@field palette_y number

---@class RenameState
---@field visible boolean
---@field input? TextInput

---@class SwapWithIndexState
---@field visible boolean
---@field input? TextInput
---@field target_index? number

---@class SessionPickerState
---@field visible boolean
---@field input? TextInput
---@field selected number
---@field scroll_offset number
---@field sessions string[]
---@field regions PaletteRegion[]
---@field renaming boolean
---@field rename_target? string

---@class FloatingPaneState
---@field visible boolean Whether the floating pane is visible
---@field width number Width in columns (default: 100)
---@field height number Height in rows (default: 30)
---@field pending boolean Whether a floating pane spawn is pending
---@field resize_mode boolean Whether resize mode is active (shows size indicator)

-- Layout definitions for predefined pane arrangements
---@class PriseLayoutPane
---@field type "pane"
---@field ratio? number Relative size (0-1)
---@field cwd? string Working directory for the shell
---@field cmd? string Command to run after shell starts

---@class PriseLayoutSplit
---@field type "split"
---@field direction "row"|"col"
---@field ratio? number Relative size of this split
---@field children (PriseLayoutPane|PriseLayoutSplit)[]

---@alias PriseLayoutNode PriseLayoutPane|PriseLayoutSplit

---@class PriseLayoutFloating
---@field pane PriseLayoutPane The floating pane definition
---@field visible? boolean Start visible (default: true)
---@field width? number Override default floating width
---@field height? number Override default floating height

---@class PriseLayoutTab
---@field title? string Tab title
---@field root PriseLayoutNode The pane/split tree
---@field floating? PriseLayoutFloating Optional floating pane for this tab

---@class PriseLayout
---@field name string Layout identifier
---@field tabs PriseLayoutTab[] Tabs in the layout
---@field active_tab? integer Which tab to focus (default: 1)

---@class LayoutPickerState
---@field visible boolean
---@field selected number
---@field scroll_offset number
---@field regions PaletteRegion[]

---@class State
---@field tabs Tab[]
---@field active_tab integer
---@field next_tab_id integer
---@field focused_id? number
---@field zoomed_pane_id? number
---@field pending_command boolean
---@field timer? Timer
---@field clock_timer? Timer
---@field pending_split? { direction: "row"|"col" }
---@field pending_new_tab? boolean
---@field pending_spawns table<number, { new_tab: boolean, no_focus: boolean }>
---@field pending_title_renames table<number, string>
---@field next_split_id number
---@field palette PaletteState
---@field rename RenameState
---@field rename_tab RenameState
---@field swap_with_index? SwapWithIndexState
---@field session_picker SessionPickerState
---@field screen_cols number
---@field screen_rows number
---@field keybind_matcher? KeybindMatcher
---@field floating FloatingPaneState
---@field layout_picker LayoutPickerState
---@field pending_layout? table

---@class Command
---@field name string|fun(): string
---@field action fun()
---@field shortcut? string
---@field visible? fun(): boolean

---@class PtyAttachEvent
---@field type "pty_attach"
---@field data { pty: Pty }

---@class PtyExitedEvent
---@field type "pty_exited"
---@field data { id: number }

---@class PtySpawnedEvent
---@field type "pty_spawned"
---@field data { id: number, cwd: string, session?: string, tab?: string, title?: string, focus?: boolean }

---@class KeyPressEvent
---@field type "key_press"
---@field data PtyKeyData

---@class KeyReleaseEvent
---@field type "key_release"
---@field data PtyKeyData

---@class PasteEvent
---@field type "paste"
---@field data { text: string }

---@class MouseEvent
---@field type "mouse"
---@field data { action: string, button?: string, x: number, y: number, target?: number, target_x?: number, target_y?: number, mods?: table }

---@class WinsizeEvent
---@field type "winsize"
---@field data { cols: number, rows: number }

---@class FocusInEvent
---@field type "focus_in"
---@field data table

---@class FocusOutEvent
---@field type "focus_out"
---@field data table

---@class SplitResizeEvent
---@field type "split_resize"
---@field data { parent_id: number, child_index: integer, ratio: number }

---@class CwdChangedEvent
---@field type "cwd_changed"
---@field data table

---@class RenameTabEvent
---@field type "rename_tab"
---@field data { pty_id: number, title: string }

---@class BreakPaneEvent
---@field type "break_pane"
---@field data { pty_id: number, focus?: boolean, source_session?: string, cwd?: string, tab_title?: string }

---@class MovePaneToSessionEvent
---@field type "move_pane_to_session"
---@field data { pty_id: number, session_name: string, cwd: string, tab_title?: string }

---@alias Event PtyAttachEvent|PtySpawnedEvent|PtyExitedEvent|KeyPressEvent|KeyReleaseEvent|PasteEvent|MouseEvent|WinsizeEvent|FocusInEvent|FocusOutEvent|SplitResizeEvent|CwdChangedEvent|RenameTabEvent|BreakPaneEvent|MovePaneToSessionEvent

-- Powerline symbols
local POWERLINE_SYMBOLS = {
    right_solid = "",
    right_thin = "",
    left_solid = "",
    left_thin = "",
    left_round = "\u{E0B6}",
    right_round = "\u{E0B4}",
}

---@class PriseThemeOptions
---@field mode_normal? string Color for normal mode indicator
---@field mode_command? string Color for command mode indicator
---@field bg1? string Darkest background
---@field bg2? string Dark background
---@field bg3? string Medium background
---@field bg4? string Lighter background
---@field fg_bright? string Main text color
---@field fg_dim? string Secondary text color
---@field fg_dark? string Dark text (on light backgrounds)
---@field accent? string Accent color
---@field green? string Success/connected color
---@field yellow? string Warning color

---@class PriseTheme
---@field mode_normal string
---@field mode_command string
---@field bg1 string
---@field bg2 string
---@field bg3 string
---@field bg4 string
---@field fg_bright string
---@field fg_dim string
---@field fg_dark string
---@field accent string
---@field green string
---@field yellow string

---@class PriseStatusBarConfig
---@field enabled? boolean Show the status bar (default: true)

---Tab info passed to custom render function
---@class TabInfo
---@field index number Tab index (1-based)
---@field title string Tab title (explicit title if set, otherwise auto-derived)
---@field is_explicit_title boolean True if this is an explicit renamed title
---@field is_active boolean True if this is the active tab
---@field is_hovered boolean True if mouse is hovering over this tab
---@field is_close_hovered boolean True if mouse is hovering over close button
---@field pane_count number Number of panes in this tab
---@field is_zoomed boolean True if this tab has a zoomed pane

---Viewport context passed to custom render functions
---@class TabRenderContext
---@field scroll_offset number Cells from the left edge of the full strip that the visible slice starts at

---Structured tab bar layout returned by custom render functions
---@class TabBarLayout
---@field prefix table[]   -- styled segments drawn at left edge, never clipped
---@field tabs table[]     -- [{ tab_index = N, label_segments = {...} }, ...]; label segments only; the inter-tab separator is owned by the core compositor and is never part of a tab's clippable width.
---@field suffix table[]   -- styled segments drawn at right edge (may be empty)
---@field gutter_left? table|table[]  -- single segment or segment list; core still owns show/hide by overflow. All-or-nothing with gutter_right.
---@field gutter_right? table|table[] -- single segment or segment list; core still owns show/hide by overflow. All-or-nothing with gutter_left.

---Filtered opts passed as the 5th arg to TabRenderFunction. Carries only the
---plain-string gutter glyphs from `config.tab_bar` — tight contract, expand
---only when future items demand new fields.
---@class TabRenderOpts
---@field gutter_left string
---@field gutter_right string

---Custom render function for tab bar
---Must return a TabBarLayout with prefix/tabs/suffix slots. The core composes
---the final strip from these three slots and applies centered-focus windowing
---plus cell-precise edge clipping to the tabs slot. When the renderer emits
---optional `gutter_left` + `gutter_right` segment fields (symmetric, all-or-
---nothing), core splices them verbatim on the sides that actually need a
---gutter (overflow) and drops them on sides that don't.
---@alias TabRenderFunction fun(tabs: TabInfo[], screen_width: number, theme: PriseTheme, ctx?: TabRenderContext, opts?: TabRenderOpts): TabBarLayout

---Measure function for tab bar viewport fit
---Must return the integer cell-width the renderer will draw for a single tab.
---Called once per tab per frame when viewport scrolling is active; missing when
---no custom `render` is set, or when the renderer opts out of scrolling.
---@alias TabMeasureFunction fun(tab: TabInfo): integer

---Optional function to format tab titles for display
---@alias TabFormatFunction fun(title: string, tab_index: number): string

---@class PriseTabBarConfig
---@field show_single_tab? boolean Show tab bar even with one tab (default: false)
---@field render? TabRenderFunction Custom tab bar renderer (overrides default design)
---@field measure? TabMeasureFunction Cell-width oracle for viewport scrolling (custom renderer only)
---@field gutter_left? string Glyph shown at the left edge when tabs are hidden off-screen; plain-string only (default: "<")
---@field gutter_right? string Glyph shown at the right edge when tabs are hidden off-screen; plain-string only (default: ">")
---@field format_title? TabFormatFunction Optional function to format tab titles (default: no formatting)

---Keybinds are a map from key_string to action name
---Example: ["<leader>v"] = "split_horizontal"
---@alias PriseKeybinds table<string, string|function>

---@class PriseBordersConfig
---@field enabled? boolean Show pane borders (default: false)
---@field show_single_pane? boolean Show border when only one pane exists (default: false)
---@field mode? "box"|"separator" Border mode: "box" for full borders, "separator" for tmux-style (default: "box")
---@field style? "none"|"single"|"double"|"rounded" Border line style (default: "single")
---@field focused_color? string Hex color for focused pane border (default: "#89b4fa")
---@field unfocused_color? string Hex color for unfocused borders (default: "#585b70")

---@class PriseFloatingConfig
---@field width? number Width in columns (default: 100)
---@field height? number Height in rows (default: 30)

---@class PriseConfigOptions
---@field theme? PriseThemeOptions Color theme options
---@field borders? PriseBordersConfig Pane border options
---@field status_bar? PriseStatusBarConfig Status bar options
---@field tab_bar? PriseTabBarConfig Tab bar options
---@field floating? PriseFloatingConfig Floating pane options
---@field leader? string Leader key sequence (default: "<D-k>")
---@field keybinds? PriseKeybinds Keybind definitions
---@field macos_option_as_alt? "false"|"left"|"right"|"true" macOS Option key behavior (default: "false")
---@field layouts? table<string, PriseLayout> Named layout definitions
---@field default_layout? string Layout to apply on startup (if no session exists)
---@field keep_attached? boolean Switch to another session when last pane exits (default: true)
---@field screen_dump? boolean Write mmap screen dumps after each render (default: false)

---@class PriseConfig
---@field theme PriseTheme
---@field borders PriseBordersConfig
---@field status_bar PriseStatusBarConfig
---@field tab_bar PriseTabBarConfig
---@field floating PriseFloatingConfig
---@field leader string
---@field keybinds PriseKeybinds
---@field layouts table<string, PriseLayout>
---@field default_layout? string
---@field keep_attached boolean
---@field screen_dump boolean

-- Default configuration
---@type PriseConfig
local config = {
    theme = {
        -- Status bar backgrounds (left to right gradient)
        mode_normal = "#89b4fa", -- Blue - normal mode
        mode_command = "#f38ba8", -- Pink - command mode
        bg1 = "#1e1e2e", -- Darkest (mode section)
        bg2 = "#313244", -- Dark (title section)
        bg3 = "#45475a", -- Medium (info section)
        bg4 = "#585b70", -- Lighter (right sections)

        -- Text colors
        fg_bright = "#cdd6f4", -- Main text
        fg_dim = "#a6adc8", -- Secondary text
        fg_dark = "#1e1e2e", -- Dark text on light bg

        -- Accent colors
        accent = "#89b4fa", -- Blue accent
        green = "#a6e3a1", -- Success/connected
        yellow = "#f9e2af", -- Warning
    },
    borders = {
        enabled = false,
        show_single_pane = false,
        mode = "box", -- "box" for full borders, "separator" for tmux-style
        style = "single",
        focused_color = "#89b4fa", -- Blue (matches default theme.accent)
        unfocused_color = "#585b70", -- Gray (matches default theme.bg4)
    },
    status_bar = {
        enabled = true,
    },
    tab_bar = {
        show_single_tab = false,
        render = nil, -- Use default built-in design
        gutter_left = "<", -- Glyph shown when tabs are hidden off the left edge
        gutter_right = ">", -- Glyph shown when tabs are hidden off the right edge
        format_title = nil, -- Use titles as-is
    },
    floating = {
        width = 100,
        height = 30,
    },
    leader = "<D-k>",
    keybinds = {
        ["<D-p>"] = "command_palette",
        ["<leader>v"] = "split_horizontal",
        ["<leader>s"] = "split_vertical",
        ["<leader><Enter>"] = "split_auto",
        ["<leader>h"] = "focus_left",
        ["<leader>l"] = "focus_right",
        ["<leader>j"] = "focus_down",
        ["<leader>k"] = "focus_up",
        ["<leader>w"] = "close_pane",
        ["<leader>z"] = "toggle_zoom",
        ["<leader>t"] = "new_tab",
        ["<leader>c"] = "close_tab",
        ["<leader>r"] = "rename_tab",
        ["<leader>n"] = "next_tab",
        ["<leader>p"] = "previous_tab",
        ["<leader><lt>"] = "swap_tab_left",
        ["<leader><gt>"] = "swap_tab_right",
        ["<leader>d"] = "detach_session",
        ["<leader>S"] = "switch_session",
        ["<leader>q"] = "quit",
        ["<leader>H"] = "resize_left",
        ["<leader>L"] = "resize_right",
        ["<leader>J"] = "resize_down",
        ["<leader>K"] = "resize_up",
        ["<leader>1"] = "tab_1",
        ["<leader>2"] = "tab_2",
        ["<leader>3"] = "tab_3",
        ["<leader>4"] = "tab_4",
        ["<leader>5"] = "tab_5",
        ["<leader>6"] = "tab_6",
        ["<leader>7"] = "tab_7",
        ["<leader>8"] = "tab_8",
        ["<leader>9"] = "tab_9",
        ["<leader>0"] = "tab_10",
        ["<leader>f"] = "floating_toggle",
        ["<leader>+"] = "floating_increase_size",
        ["<leader>-"] = "floating_decrease_size",
        ["<leader>o"] = "layout_picker",
    },
    macos_option_as_alt = "false",
    screen_dump = false,
    layouts = {},
    default_layout = nil,
    keep_attached = true,
}

local merge_config = utils.merge_config

-- Convenience alias for theme access
local THEME = config.theme

---@type State
local state = {
    tabs = {},
    active_tab = 1,
    next_tab_id = 1,
    focused_id = nil,
    zoomed_pane_id = nil,
    app_focused = true,
    pending_command = false,
    timer = nil,
    clock_timer = nil,
    pending_split = nil,
    pending_new_tab = false, -- keyboard-initiated new tab (PTY ID not yet known)
    pending_spawns = {}, -- [pty_id] = { new_tab = bool, no_focus = bool }
    pending_title_renames = {}, -- [pty_id] = title string from spawn placement
    next_split_id = 1,
    -- Command palette
    palette = {
        visible = false,
        input = nil, -- TextInput handle
        selected = 1,
        scroll_offset = 0,
        regions = {}, -- Click regions for items
        palette_y = 5, -- Y offset of the palette
    },
    -- Rename session prompt
    rename = {
        visible = false,
        input = nil, -- TextInput handle
    },
    -- Rename tab prompt
    rename_tab = {
        visible = false,
        input = nil, -- TextInput handle
    },
    -- Swap tab with index dialog
    swap_with_index = nil,
    -- Session switcher
    session_picker = {
        visible = false,
        input = nil, -- TextInput handle
        selected = 1,
        scroll_offset = 0,
        sessions = {}, -- List of session names
        regions = {}, -- Click regions for items
        renaming = false, -- Whether we're renaming a session
        rename_target = nil, -- The session being renamed
    },
    -- Tab bar hit regions: array of {start_x, end_x, tab_index}
    -- Recorded in on-screen coordinates (0..screen_cols) AFTER any viewport
    -- shift, so the mouse consumer at `d.x < 1` compares directly.
    tab_regions = {},
    -- Tab close button regions: array of {start_x, end_x, tab_index}
    tab_close_regions = {},
    -- Latch for `config.tab_bar.render` callback failure. Once the callback
    -- errors / returns a malformed layout (missing prefix/tabs/suffix, bad tab
    -- entries), we log warn ONCE and render an empty strip for the rest of
    -- the session. Session-scoped so a config hot-reload via M.setup() resets.
    tab_bar_render_warned = false,
    -- Currently hovered tab index (nil if none)
    hovered_tab = nil,
    -- Currently hovered close button tab index (nil if none)
    hovered_close_tab = nil,
    -- Screen dimensions
    screen_cols = 80,
    screen_rows = 24,
    -- Cached git branch (updated on cwd_changed)
    cached_git_branch = nil,
    -- True when detaching (prevents new timers from being scheduled)
    detaching = false,
    -- Keybind matcher (initialized by init_keybinds)
    keybind_matcher = nil,
    -- Floating pane state
    floating = {
        visible = false,
        width = 100,
        height = 30,
        pending = false,
        resize_mode = false,
    },
    -- Layout picker state
    layout_picker = {
        visible = false,
        selected = 1,
        scroll_offset = 0,
        regions = {},
    },
    -- Pending layout to apply (layout node definitions waiting for PTY spawns)
    pending_layout = nil,
}

local function reset_session_state()
    if state.timer then
        state.timer:cancel()
        state.timer = nil
    end

    state.tabs = {}
    state.active_tab = 1
    state.next_tab_id = 1
    state.focused_id = nil
    state.zoomed_pane_id = nil
    state.pending_command = false
    state.pending_split = nil
    state.pending_new_tab = false
    state.next_split_id = 1

    state.palette.visible = false
    state.palette.selected = 1
    state.palette.scroll_offset = 0
    state.palette.regions = {}
    if state.palette.input then
        state.palette.input:clear()
    end

    state.rename.visible = false
    if state.rename.input then
        state.rename.input:clear()
    end

    state.rename_tab.visible = false
    if state.rename_tab.input then
        state.rename_tab.input:clear()
    end

    state.swap_with_index = nil

    state.session_picker.visible = false
    state.session_picker.selected = 1
    state.session_picker.scroll_offset = 0
    state.session_picker.sessions = {}
    state.session_picker.regions = {}
    state.session_picker.renaming = false
    state.session_picker.rename_target = nil
    if state.session_picker.input then
        state.session_picker.input:clear()
    end

    state.layout_picker.visible = false
    state.layout_picker.selected = 1
    state.layout_picker.scroll_offset = 0
    state.layout_picker.regions = {}

    state.tab_regions = {}
    state.tab_close_regions = {}
    state.hovered_tab = nil
    state.hovered_close_tab = nil
    state.cached_git_branch = nil
    state.detaching = false
    state.floating.visible = false
    state.floating.pending = false
    state.floating.resize_mode = false
end

local M = {}

---Forward declaration for action_handlers (defined after helper functions)
---@type table<string, fun()>
local action_handlers

---Initialize keybinds by compiling the trie
local function init_keybinds()
    if state.keybind_matcher then
        return
    end
    state.keybind_matcher = prise.keybind.compile(config.keybinds, config.leader)
end

---Configure the default UI
---@param opts? PriseConfigOptions Configuration options to merge
function M.setup(opts)
    if opts then
        merge_config(config, opts)
    end
    -- Apply floating pane config to state
    state.floating.width = config.floating.width
    state.floating.height = config.floating.height
    -- Mark keybinds for re-initialization on next key event
    -- (lazy init because UI pointer may not be available during config loading)
    state.keybind_matcher = nil
end

---Get the macos_option_as_alt setting
---@return string
function M.get_macos_option_as_alt()
    return config.macos_option_as_alt or "false"
end

---Get the resolved theme (defaults merged with user overrides from setup())
---@return PriseTheme
function M.get_theme()
    return config.theme
end

---Get the screen_dump setting
---@return boolean
function M.get_screen_dump()
    return config.screen_dump or false
end

local RESIZE_STEP = 0.05 -- 5% step for keyboard resize
local PALETTE_WIDTH = 60 -- Total width of command palette
local PALETTE_INNER_WIDTH = 56 -- Inner width (PALETTE_WIDTH - 4 for padding)

---@return integer start_x
---@return integer end_x
local function modal_x_bounds()
    local start_x = math.floor((state.screen_cols - PALETTE_WIDTH) / 2)
    return start_x, start_x + PALETTE_WIDTH
end

-- Floating pane size bounds
local FLOATING_MIN_WIDTH = 40
local FLOATING_MAX_WIDTH = 200
local FLOATING_MIN_HEIGHT = 10
local FLOATING_MAX_HEIGHT = 50
local FLOATING_WIDTH_STEP = 5
local FLOATING_HEIGHT_STEP = 2

-- --- Helpers ---

---Handle common text input key events
---@param input TextInput
---@param key_data PtyKeyData
---@return boolean handled
local function handle_text_input_key(input, key_data)
    local k = key_data.key
    local ctrl = key_data.ctrl

    if k == "Backspace" and not key_data.alt then
        input:delete_backward()
        prise.request_frame()
        return true
    elseif k == "Delete" then
        input:delete_forward()
        prise.request_frame()
        return true
    elseif k == "w" and ctrl then
        input:delete_word_backward()
        prise.request_frame()
        return true
    elseif k == "k" and ctrl then
        input:kill_line()
        prise.request_frame()
        return true
    elseif k == "ArrowLeft" and key_data.alt then
        input:move_word_backward()
        prise.request_frame()
        return true
    elseif k == "ArrowRight" and key_data.alt then
        input:move_word_forward()
        prise.request_frame()
        return true
    elseif k == "ArrowLeft" then
        input:move_left()
        prise.request_frame()
        return true
    elseif k == "ArrowRight" then
        input:move_right()
        prise.request_frame()
        return true
    elseif k == "Home" or (k == "a" and ctrl) then
        input:move_to_start()
        prise.request_frame()
        return true
    elseif k == "End" or (k == "e" and ctrl) then
        input:move_to_end()
        prise.request_frame()
        return true
    elseif k == "u" and ctrl then
        input:delete_to_start()
        prise.request_frame()
        return true
    elseif k == "d" and ctrl then
        input:delete_forward()
        prise.request_frame()
        return true
    elseif k == "h" and ctrl then
        input:delete_backward()
        prise.request_frame()
        return true
    elseif k == "b" and ctrl then
        input:move_left()
        prise.request_frame()
        return true
    elseif k == "f" and ctrl then
        input:move_right()
        prise.request_frame()
        return true
    elseif k == "b" and key_data.alt then
        input:move_word_backward()
        prise.request_frame()
        return true
    elseif k == "f" and key_data.alt then
        input:move_word_forward()
        prise.request_frame()
        return true
    elseif k == "d" and key_data.alt then
        input:delete_word_after()
        prise.request_frame()
        return true
    elseif k == "Backspace" and key_data.alt then
        input:delete_word_backward()
        prise.request_frame()
        return true
    elseif #k == 1 and not ctrl and not key_data.alt and not key_data.super then
        input:insert(k)
        prise.request_frame()
        return true
    end

    return false
end

---@param node? table
---@return boolean
local function is_pane(node)
    return node ~= nil and node.type == "pane"
end

---@param node? table
---@return boolean
local function is_split(node)
    return node ~= nil and node.type == "split"
end

---Check if a key is a modifier-only key (Shift, Ctrl, Alt, Super)
---@param key string
---@return boolean
local function is_modifier_key(key)
    return key == "ShiftLeft"
        or key == "ShiftRight"
        or key == "ControlLeft"
        or key == "ControlRight"
        or key == "AltLeft"
        or key == "AltRight"
        or key == "MetaLeft"
        or key == "MetaRight"
end

---Cancel all timers and detach from session
local function detach_session()
    state.detaching = true
    if state.clock_timer then
        state.clock_timer:cancel()
        state.clock_timer = nil
    end
    if state.timer then
        state.timer:cancel()
        state.timer = nil
    end
    prise.detach(prise.get_session_name())
end

---Close a session (refuses non-empty sessions, re-anchors the viewer
---when closing the current session, and flushes save).
---
---Invariants:
---  * Refuses on bad args (non-string or empty name). Returns false.
---  * When `session_name` matches the current viewer session and
---    `#state.tabs > 0`, refuses. The caller is responsible for
---    draining tabs first (e.g. `move_pane_to_session` empties the
---    source tab tree before calling here).
---  * When `session_name` matches the current viewer session and
---    `#state.tabs == 0`:
---      * If another session is listed by `prise.list_sessions()` the
---        viewer switches to it BEFORE the file delete, so the viewer
---        is never anchored on a non-existent session.
---      * If no other session exists, prise tolerates the transient
---        zero-sessions state until the next operation creates one.
---        Document at the call site why the zero-sessions gap is OK.
---  * When `session_name` does NOT match the current viewer session,
---    emptiness can't be checked from viewer state — the file delete
---    proceeds unconditionally (this matches `prise.delete_session`'s
---    idempotent-on-ENOENT contract). Callers that need non-empty
---    protection for off-viewer sessions must pre-check before
---    invoking this helper.
---  * Always flushes `prise.save()` after a successful close so
---    source state and on-disk state agree.
---
---@param session_name string
---@return boolean ok
local function close_session(session_name)
    if type(session_name) ~= "string" or session_name == "" then
        return false
    end
    local current = prise.get_session_name()
    if current == session_name then
        -- Refuse non-empty close for the current session. For
        -- off-viewer sessions we have no way to enumerate tabs;
        -- callers own that check.
        if #state.tabs > 0 then
            prise.log.warn(
                "close_session: refusing non-empty current session="
                    .. tostring(session_name)
                    .. " tab_count="
                    .. tostring(#state.tabs)
            )
            return false
        end
        -- Viewer re-anchor: pick any other session if one exists.
        -- prise.list_sessions returns the current session name too;
        -- skip it.
        local fallback = nil
        local sessions = prise.list_sessions() or {}
        for _, name in ipairs(sessions) do
            if name ~= session_name then
                fallback = name
                break
            end
        end
        if fallback then
            prise.switch_session(fallback)
        end
        -- No `else` branch: prise tolerates the momentary
        -- zero-sessions state until the next op creates one.
    end
    local deleted = prise.delete_session(session_name)
    -- delete_session returns false only when no callback is wired
    -- (tests may mock it permissively) — treat that as fatal so we
    -- don't flush an inconsistent state.
    if deleted == false then
        return false
    end
    prise.save()
    return true
end
-- Expose on the prise module so external Lua code (and tests via the
-- mock prise table) can invoke `prise.close_session(name)`. The
-- policy logic above belongs to tiling.lua because only this layer
-- holds viewer state (state.tabs, active session); the registration
-- makes the helper reachable without widening the Zig surface.
if prise and not prise.close_session then
    prise.close_session = close_session
end

---Get the currently active tab
---@return Tab?
local function get_active_tab()
    return state.tabs[state.active_tab]
end

---Get the root node of the active tab
---@return Node?
local function get_active_root()
    local tab = get_active_tab()
    return tab and tab.root or nil
end

---Forward declaration for find_node_path
---@type fun(current: Node?, target_id: number, path: Node[]?): Node[]?
local find_node_path

---Find which tab contains a pane by id
---@param pane_id number
---@return integer?, Tab?
local function find_tab_for_pane(pane_id)
    for i, tab in ipairs(state.tabs) do
        if find_node_path(tab.root, pane_id) then
            return i, tab
        end
        if tab.floating and tab.floating.pane and tab.floating.pane.id == pane_id then
            return i, tab
        end
    end
    return nil
end

---Find a tab by its title
---@param title string
---@return integer?, Tab?
local function find_tab_by_title(title)
    for i, tab in ipairs(state.tabs) do
        if tab.title == title then
            return i, tab
        end
    end
    return nil
end

---Collect all panes in a node tree
---@param node? Node
---@param acc? Pane[]
---@return Pane[]
local function collect_panes(node, acc)
    acc = acc or {}
    if not node then
        return acc
    end
    if is_pane(node) then
        table.insert(acc, node)
    elseif is_split(node) then
        for _, child in ipairs(node.children) do
            collect_panes(child, acc)
        end
    end
    return acc
end

---Collect all panes belonging to a tab, including its floating pane.
---@param tab? Tab
---@return Pane[]
local function collect_tab_panes(tab)
    local panes = collect_panes(tab and tab.root or nil, {})
    if tab and tab.floating and tab.floating.pane then
        table.insert(panes, tab.floating.pane)
    end
    return panes
end

---Returns a list of nodes from root to the target node [root, ..., target]
---@param current? Node
---@param target_id number
---@param path? Node[]
---@return Node[]?
find_node_path = function(current, target_id, path)
    path = path or {}
    if not current then
        return nil
    end

    table.insert(path, current)

    if is_pane(current) then
        if current.id == target_id then
            return path
        end
    elseif is_split(current) then
        for _, child in ipairs(current.children) do
            if find_node_path(child, target_id, path) then
                return path
            end
        end
    end

    -- Not found in this branch
    table.remove(path)
    return nil
end

---List pty_ids of all main-tree panes sharing a tab with pty_id.
---Returns nil if pty_id is unknown or lives in a floating/overlay slot
---rather than the tileable tree. Traversal order matches collect_panes.
---@param pty_id number
---@return number[]?
function M.list_tab_pty_ids(pty_id)
    local _, tab = find_tab_for_pane(pty_id)
    if not tab then
        return nil
    end
    -- find_tab_for_pane may resolve floating/overlay panes (held on
    -- tab.floating, outside tab.root). Filter them out here — this
    -- primitive only reports main-tileable-tree cohabitants, because
    -- that is what break_pane can act on. Callers that care about
    -- floats should reach for tab.floating through a different API.
    if not find_node_path(tab.root, pty_id) then
        return nil
    end
    local panes = collect_panes(tab.root, {})
    local ids = {}
    for _, p in ipairs(panes) do
        table.insert(ids, p.id)
    end
    return ids
end

---Classify whether a break_pane operation is safe for the given pty_id.
---Pure read-only — never mutates state. External callers (e.g. the RPC
---layer) must call this before dispatching the break_pane event to get a
---structured reason token rather than a plain boolean from the handler.
---
---Returns one of:
---  "ok"                — pty is in tile tree, tab has 2+ panes; break is safe.
---  "solo_pane"         — pty is the only pane in its tab's tile tree.
---  "pty_not_tileable"  — pty exists in a floating/overlay slot, not the tree.
---  "pty_not_in_session"— pty is known (state.ptys) but not in any tab tree or
---                        floating slot (cross-session / foreign-session case).
---  "pty_not_found"     — pty_id unknown to this session entirely.
---
---@param pty_id number
---@return "ok"|"solo_pane"|"pty_not_tileable"|"pty_not_in_session"|"pty_not_found"
function M.classify_break_pane(pty_id)
    -- Resolve the owning tab. find_tab_for_pane semantics shift across
    -- branches: on this branch it walks tab.root only, but on arthack-prod
    -- (after feat/overlay-terminals merges) it also matches tab.floating.
    -- Don't lean on its tree-only-ness — verify membership explicitly below.
    local src_tab_idx, src_tab = find_tab_for_pane(pty_id)
    if src_tab and find_node_path(src_tab.root, pty_id) then
        -- Pane is in the tileable tree.
        if is_pane(src_tab.root) and src_tab.root.id == pty_id then
            return "solo_pane"
        end
        _ = src_tab_idx -- suppress unused warning
        return "ok"
    end

    -- Not in any tile tree. Check floating/overlay slots across all tabs.
    for _, tab in ipairs(state.tabs) do
        if tab.floating and tab.floating.pane and tab.floating.pane.id == pty_id then
            return "pty_not_tileable"
        end
        if tab.overlays then
            for _, overlay in pairs(tab.overlays) do
                if overlay.pane and overlay.pane.id == pty_id then
                    return "pty_not_tileable"
                end
            end
        end
    end

    -- Not in any tab at all. If the session has a pty registry and the id
    -- is there, the pane belongs to a different session (cross-session arm).
    -- state.ptys is not present in v1 live runtime — this arm is reachable
    -- from tests that inject state.ptys to exercise the token.
    if state.ptys and state.ptys[pty_id] then
        return "pty_not_in_session"
    end

    return "pty_not_found"
end

---Broker entrypoint for the break_pane RPC. The server picks one
---attached client (lowest stable Client.id) as broker and asks it via
---an `app.ui.update({type="break_pane_request",...})` event. We
---classify, apply on "ok", and reply via `prise.notify("break_pane_reply",...)`.
---
---Defensive guard: the inner `M.update({type="break_pane",...})` call
---is constructed with a clean two-field `data` table — only `pty_id`
---and `focus`. We never pass through `source_session` or any other
---field that would route through the `M.update :3317` cross-session
---arm (which references nil-on-this-branch globals
---`prise.remove_pty_from_session` / `prise.place_pty_in_session`).
---That arm stays asleep when `event.data.source_session` is nil/empty.
---
---@param pty_id number
---@param focus boolean
---@param request_id number
function M.handle_break_pane_request(pty_id, focus, request_id)
    local verdict = M.classify_break_pane(pty_id)
    local ok = verdict == "ok"

    if ok then
        -- Apply locally first so siblings see the broker's tile-tree
        -- AFTER the mutation completes. Pass `data` as exactly two
        -- fields — pty_id and focus — to keep the cross-session bomb
        -- at tiling.lua:3317 asleep.
        M.update({
            type = "break_pane",
            data = { pty_id = pty_id, focus = focus },
        })
    end

    -- Reply to the server. Notification envelope is fire-and-forget —
    -- no ack expected. The server correlates by request_id and
    -- forwards the verdict to the originating CLI.
    prise.notify("break_pane_reply", {
        request_id = request_id,
        ok = ok,
        reason = verdict,
    })
end

---Convergence entrypoint for non-broker clients. After the broker
---applies the break_pane, the server fans out a `break_pane_applied`
---broadcast to other attached clients so their tile-tree mirrors
---catch up. We re-run the same mutation locally.
---
---Defensive guard: same as `handle_break_pane_request` — `data` is a
---clean two-field table to keep the cross-session arm asleep.
---
---Idempotency: if `pty_id` is unknown to this client (e.g. attached
---to a different session), `M.update`'s break_pane arm short-circuits
---on `not src_tab` (with `source_session` nil) and returns false
---without mutating state. No crash.
---
---@param pty_id number
---@param focus boolean
function M.handle_break_pane_applied(pty_id, focus)
    M.update({
        type = "break_pane",
        data = { pty_id = pty_id, focus = focus },
    })
end

---@param node? Node
---@return Pane?
local function get_first_leaf(node)
    if not node then
        return nil
    end
    if node.type == "pane" then
        ---@cast node Pane
        return node
    end
    if node.type == "split" then
        ---@cast node Split
        return get_first_leaf(node.children[1])
    end
    return nil
end

---@param node? Node
---@return Pane?
local function get_last_leaf(node)
    if not node then
        return nil
    end
    if node.type == "pane" then
        ---@cast node Pane
        return node
    end
    if node.type == "split" then
        ---@cast node Split
        return get_last_leaf(node.children[#node.children])
    end
    return nil
end

---Update the cached git branch for the focused pane
local function update_cached_git_branch()
    local root = get_active_root()
    if state.focused_id and root then
        local path = find_node_path(root, state.focused_id)
        if path then
            local pane = path[#path]
            local cwd = pane.pty:cwd()
            if cwd then
                state.cached_git_branch = prise.get_git_branch(cwd)
                return
            end
        end
    end
    state.cached_git_branch = nil
end

---Recursively insert a new pane relative to target_id
---@param node Node
---@param target_id number
---@param new_pane Pane
---@param direction "row"|"col"
---@return Node
local function insert_split_recursive(node, target_id, new_pane, direction)
    if is_pane(node) then
        if node.id == target_id then
            -- Found the target pane. Replace it with a split containing [node, new_pane]
            local split_ratio = node.ratio -- Inherit ratio from the pane being replaced
            node.ratio = nil -- Children start with nil (equal split)
            new_pane.ratio = nil
            local split_id = state.next_split_id
            state.next_split_id = state.next_split_id + 1
            return {
                type = "split",
                split_id = split_id,
                direction = direction,
                ratio = split_ratio,
                children = { node, new_pane },
            }
        else
            return node
        end
    elseif is_split(node) then
        for i, child in ipairs(node.children) do
            node.children[i] = insert_split_recursive(child, target_id, new_pane, direction)
        end
        return node
    end
    return node
end

---Recursively remove a pane and return: new_node, closest_sibling_id
---@param node Node
---@param id number
---@return Node?, number?
local function remove_pane_recursive(node, id)
    if is_pane(node) then
        if node.id == id then
            return nil, nil
        end -- Remove this pane
        return node, nil
    elseif is_split(node) then
        local new_children = {}
        local removed_index = nil
        local closest_id = nil

        for i, child in ipairs(node.children) do
            local res, sibling_from_below = remove_pane_recursive(child, id)

            if res then
                table.insert(new_children, res)
                if sibling_from_below then
                    closest_id = sibling_from_below
                end
            else
                -- This child was removed
                removed_index = i
                if sibling_from_below then
                    closest_id = sibling_from_below
                end
            end
        end

        -- If we found the removed node at this level, pick a sibling
        if removed_index and not closest_id then
            -- Try right sibling first (if exists), then left
            if removed_index < #node.children then
                local neighbor = node.children[removed_index + 1]
                local leaf = get_first_leaf(neighbor)
                if leaf then
                    closest_id = leaf.id
                end
            elseif removed_index > 1 then
                local neighbor = node.children[removed_index - 1]
                local leaf = get_last_leaf(neighbor)
                if leaf then
                    closest_id = leaf.id
                end
            end
        end

        if #new_children == 0 then
            return nil, closest_id
        end

        -- If only one child remains, promote it
        if #new_children == 1 then
            ---@type Node
            local survivor = new_children[1]
            survivor.ratio = node.ratio -- Inherit ratio from parent
            return survivor, closest_id
        end

        node.children = new_children
        return node, closest_id
    end
    return nil, nil
end

---@return Pty?
local function get_focused_pty()
    local root = get_active_root()
    if not state.focused_id or not root then
        return nil
    end
    local path = find_node_path(root, state.focused_id)
    if path then
        return path[#path].pty
    end
    return nil
end

---Get the floating pane's PTY if visible, nil otherwise
---@return Pty?
local function get_visible_floating_pty()
    local tab = get_active_tab()
    if tab and tab.floating and tab.floating.visible and tab.floating.pane then
        return tab.floating.pane.pty
    end
    return nil
end

local function get_auto_split_direction()
    local pty = get_focused_pty()
    if pty then
        local size = pty:size()
        ---@type boolean
        local wider
        if size.width_px > 0 and size.height_px > 0 then
            wider = size.width_px > size.height_px
        else
            wider = size.cols > size.rows
        end
        if wider then
            return "row"
        else
            return "col"
        end
    end
    return "row"
end

local function update_pty_focus(old_id, new_id)
    if old_id == new_id then
        return
    end
    if old_id then
        local _, old_tab = find_tab_for_pane(old_id)
        if old_tab then
            local old_path = find_node_path(old_tab.root, old_id)
            if old_path then
                old_path[#old_path].pty:set_focus(false)
            end
        end
    end
    if new_id and state.app_focused then
        local _, new_tab = find_tab_for_pane(new_id)
        if new_tab then
            local new_path = find_node_path(new_tab.root, new_id)
            if new_path then
                new_path[#new_path].pty:set_focus(true)
            end
        end
    end
end

---Switch to a different tab by index
---@param new_index integer
local function set_active_tab_index(new_index)
    if new_index < 1 or new_index > #state.tabs then
        return
    end
    if new_index == state.active_tab then
        return
    end

    local old_tab = state.tabs[state.active_tab]
    local old_focused = state.focused_id

    -- Save zoom and focus state to old tab
    if old_tab then
        old_tab.zoomed_pane_id = state.zoomed_pane_id
        old_tab.last_focused_id = state.focused_id
    end

    state.active_tab = new_index
    local new_tab = state.tabs[new_index]
    if not new_tab then
        return
    end

    -- Restore zoom state from new tab (clear saved value; active tab uses state.zoomed_pane_id)
    state.zoomed_pane_id = new_tab.zoomed_pane_id
    new_tab.zoomed_pane_id = nil

    -- Pick new focused pane in this tab
    local new_focus_id = new_tab.last_focused_id
    if not new_focus_id or not find_node_path(new_tab.root, new_focus_id) then
        local first_pane = get_first_leaf(new_tab.root)
        new_focus_id = first_pane and first_pane.id or nil
    end

    state.focused_id = new_focus_id
    update_pty_focus(old_focused, new_focus_id)
    update_cached_git_branch()
    prise.request_frame()
end

---Close the current tab
---Close tab at given index
---@param idx integer
local function close_tab(idx)
    if #state.tabs == 0 then
        return
    end

    local tab = state.tabs[idx]
    if not tab then
        return
    end

    -- If this is the last tab, quit the app
    if #state.tabs == 1 then
        local panes = collect_tab_panes(tab)
        for _, pane in ipairs(panes) do
            if pane.pty and pane.pty.close then
                pane.pty:close()
            end
        end
        -- Cancel clock timer before exit
        if state.clock_timer then
            state.clock_timer:cancel()
            state.clock_timer = nil
        end
        prise.exit()
        return
    end

    -- Close all PTYs in this tab
    local panes = collect_tab_panes(tab)
    for _, pane in ipairs(panes) do
        if pane.pty and pane.pty.close then
            pane.pty:close()
        end
    end

    -- Save zoom to the closing tab so we can detect active-tab changes
    local closing_active = (idx == state.active_tab)
    if closing_active then
        tab.zoomed_pane_id = state.zoomed_pane_id
    end

    local old_focused = state.focused_id
    table.remove(state.tabs, idx)

    -- Pick new active tab index
    if idx > #state.tabs then
        idx = #state.tabs
    end
    state.active_tab = idx > 0 and idx or 1

    local new_tab = state.tabs[state.active_tab]
    if new_tab then
        -- Only restore zoom when we landed on a different tab
        if closing_active then
            state.zoomed_pane_id = new_tab.zoomed_pane_id
            new_tab.zoomed_pane_id = nil
        end

        -- Choose focused pane in new tab
        local new_focus_id = new_tab.last_focused_id
        if not new_focus_id or not find_node_path(new_tab.root, new_focus_id) then
            local first_pane = get_first_leaf(new_tab.root)
            new_focus_id = first_pane and first_pane.id or nil
        end
        state.focused_id = new_focus_id
        update_pty_focus(old_focused, new_focus_id)
        update_cached_git_branch()
    else
        -- No tabs left
        state.focused_id = nil
        state.cached_git_branch = nil
    end

    prise.request_frame()
    prise.save()
end

---Close the current tab
local function close_current_tab()
    close_tab(state.active_tab)
end

---Swap two tabs by their indices
---@param idx1 integer
---@param idx2 integer
local function swap_tabs(idx1, idx2)
    if idx1 < 1 or idx1 > #state.tabs or idx2 < 1 or idx2 > #state.tabs then
        return
    end
    if idx1 == idx2 then
        return
    end

    -- Swap the tabs
    state.tabs[idx1], state.tabs[idx2] = state.tabs[idx2], state.tabs[idx1]

    -- Update active_tab if it was swapped
    if state.active_tab == idx1 then
        state.active_tab = idx2
    elseif state.active_tab == idx2 then
        state.active_tab = idx1
    end

    prise.request_frame()
    prise.save()
end

---Close any floating and overlay panes attached to a tab.
---Used before dropping a tab whose main-tree root has been emptied,
---so auxiliary panes don't become orphaned.
---@param tab Tab
local function close_auxiliary_panes(tab)
    if tab.floating and tab.floating.pane then
        local fp = tab.floating.pane
        if fp.pty and fp.pty.close then
            fp.pty:close()
        end
    end
    if tab.overlays then
        for _, overlay in pairs(tab.overlays) do
            if overlay.pane and overlay.pane.pty and overlay.pane.pty.close then
                overlay.pane.pty:close()
            end
        end
    end
end

---Remove a pane by id from the appropriate tab
---@param id number
---@return boolean was_last True if this was the last pane in the last tab (app will quit)
local function remove_pane_by_id(id)
    local tab_idx, tab = find_tab_for_pane(id)
    if not tab then
        return false
    end

    -- Clear zoom if the zoomed pane is being removed
    if state.zoomed_pane_id == id then
        state.zoomed_pane_id = nil
    end
    -- Also clear per-tab saved zoom if it references this pane
    for _, t in ipairs(state.tabs) do
        if t.zoomed_pane_id == id then
            t.zoomed_pane_id = nil
        end
    end

    local new_root, next_focus = remove_pane_recursive(tab.root, id)
    tab.root = new_root

    if not tab.root then
        -- Close floating/overlay panes that would be orphaned by
        -- dropping this tab.
        close_auxiliary_panes(tab)
        -- Tab is now empty, remove it
        if #state.tabs == 1 then
            table.remove(state.tabs, tab_idx)
            -- Cancel clock timer before exit
            if state.clock_timer then
                state.clock_timer:cancel()
                state.clock_timer = nil
            end
            -- Try switching to another session instead of exiting
            if config.keep_attached then
                local sessions = prise.list_sessions() or {}
                local current = prise.get_session_name()
                -- Delete the departing session's saved state BEFORE the switch loop.
                -- Placement-before-loop covers three cases: switch-success (survivor
                -- client must not see the empty state on its next load), every
                -- switch-fails case, and the fall-through to prise.exit() (the exit
                -- callback's own deleteCurrentSession then becomes a safe no-op on
                -- ENOENT, guaranteed by App.deleteSession's idempotent contract).
                -- Without this, the Zig save branch in switchToSession re-creates the
                -- file: surfaces.count() hasn't dropped yet because the async
                -- pty_exited hasn't caught up, so the save thinks state is still live.
                prise.delete_session(current)
                for _, s in ipairs(sessions) do
                    if s ~= current then
                        if prise.switch_session(s) then
                            return true
                        end
                    end
                end
            end
            prise.exit()
            return true
        else
            local old_focused = state.focused_id
            local was_active = (tab_idx == state.active_tab)
            table.remove(state.tabs, tab_idx)

            -- Adjust active_tab if needed
            if state.active_tab > #state.tabs then
                state.active_tab = #state.tabs
            end
            if state.active_tab < 1 then
                state.active_tab = 1
            end

            -- Update focus to new active tab
            local new_tab = state.tabs[state.active_tab]
            if new_tab then
                -- Restore zoom from new tab when the collapsed tab was active
                if was_active then
                    state.zoomed_pane_id = new_tab.zoomed_pane_id
                    new_tab.zoomed_pane_id = nil
                end

                local new_focus_id = new_tab.last_focused_id
                if not new_focus_id or not find_node_path(new_tab.root, new_focus_id) then
                    local first_pane = get_first_leaf(new_tab.root)
                    new_focus_id = first_pane and first_pane.id or nil
                end
                state.focused_id = new_focus_id
                update_pty_focus(old_focused, new_focus_id)
                update_cached_git_branch()
            end
            prise.request_frame()
            return false
        end
    else
        -- Tab still has panes
        if state.focused_id == id then
            local old_id = state.focused_id
            if next_focus then
                state.focused_id = next_focus
            else
                local first = get_first_leaf(tab.root)
                if first then
                    state.focused_id = first.id
                end
            end
            update_pty_focus(old_id, state.focused_id)
            update_cached_git_branch()
        end
        prise.request_frame()
        return false
    end
end

---Count all panes in the tree
---@param node? Node
---@return number
local function count_panes(node)
    if not node then
        return 0
    end
    if is_pane(node) then
        return 1
    end
    if is_split(node) then
        local count = 0
        for _, child in ipairs(node.children) do
            count = count + count_panes(child)
        end
        return count
    end
    return 0
end

---Count all panes belonging to a tab, including its floating pane.
---@param tab? Tab
---@return number
local function count_tab_panes(tab)
    local n = count_panes(tab and tab.root or nil)
    if tab and tab.floating and tab.floating.pane then
        n = n + 1
    end
    return n
end

---Determine if borders should be shown for the active tab
---@return boolean
local function should_show_borders()
    if not config.borders.enabled then
        return false
    end
    if config.borders.show_single_pane then
        return true
    end
    local root = get_active_root()
    return count_panes(root) > 1
end

---Check if a node subtree contains the focused pane
---@param node Node
---@return boolean
local function contains_focused(node)
    if not node or not state.focused_id then
        return false
    end
    if is_pane(node) then
        return node.id == state.focused_id
    elseif is_split(node) then
        for _, child in ipairs(node.children) do
            if contains_focused(child) then
                return true
            end
        end
    end
    return false
end

---Serialize a node tree to a table with pty_ids instead of userdata
---@param node? Node
---@param cwd_lookup? fun(pty_id: number): string?
---@return table?
local function serialize_node(node, cwd_lookup)
    if not node then
        return nil
    end
    if is_pane(node) then
        if node.pty == nil then
            return {
                type = "pane",
                id = node.id,
                pty_id = node.pty_id,
                cwd = node.cwd,
                ratio = node.ratio,
            }
        end
        local pty_id = node.pty:id()
        ---@type string?
        local cwd = nil
        if cwd_lookup then
            cwd = cwd_lookup(pty_id)
        end
        return {
            type = "pane",
            id = node.id,
            pty_id = pty_id,
            cwd = cwd,
            ratio = node.ratio,
        }
    elseif is_split(node) then
        local children = {}
        for _, child in ipairs(node.children) do
            table.insert(children, serialize_node(child, cwd_lookup))
        end
        return {
            type = "split",
            split_id = node.split_id,
            direction = node.direction,
            ratio = node.ratio,
            children = children,
        }
    end
    return nil
end

---Deserialize a node tree, looking up PTYs by id.
---If `remap` is provided, records `saved.id -> new_id` for each pane so
---callers can translate persisted focus references (focused_id,
---last_focused_id) onto the remapped id space.
---@param saved? table
---@param pty_lookup fun(id: number): Pty?
---@param remap? table<number, number>
---@return Node?
local function deserialize_node(saved, pty_lookup, remap)
    if not saved then
        return nil
    end
    if saved.type == "pane" then
        local pty = pty_lookup(saved.pty_id)
        if not pty then
            return nil
        end
        local new_id = pty:id()
        if remap and saved.id then
            remap[saved.id] = new_id
        end
        return {
            type = "pane",
            id = new_id,
            pty = pty,
            cwd = saved.cwd, -- Store cwd for spawn fallback
            ratio = saved.ratio,
        }
    elseif saved.type == "split" then
        ---@type Node[]
        local children = {}
        for _, child in ipairs(saved.children) do
            local restored = deserialize_node(child, pty_lookup, remap)
            if restored then
                table.insert(children, restored)
            end
        end
        if #children == 0 then
            return nil
        elseif #children == 1 then
            ---@type Node
            local survivor = children[1]
            survivor.ratio = saved.ratio
            return survivor
        end
        return {
            type = "split",
            split_id = saved.split_id,
            direction = saved.direction,
            ratio = saved.ratio,
            children = children,
        }
    end
    return nil
end

---Serialize a floating pane for session persistence
---@param floating? FloatingPane
---@param cwd_lookup? fun(pty_id: number): string?
---@return table?
local function serialize_floating(floating, cwd_lookup)
    if not floating or not floating.pane or not floating.pane.pty then
        return nil
    end
    local pty_id = floating.pane.pty:id()
    ---@type string?
    local cwd = nil
    if cwd_lookup then
        cwd = cwd_lookup(pty_id)
    end
    return {
        pane = {
            type = "pane",
            id = floating.pane.id,
            pty_id = pty_id,
            cwd = cwd,
        },
        visible = floating.visible,
    }
end

---Deserialize a floating pane, looking up PTY by id.
---If `remap` is provided, records the floating pane's `saved.pane.id -> new_id`
---mapping for focus translation.
---@param saved? table
---@param pty_lookup fun(id: number): Pty?
---@param remap? table<number, number>
---@return FloatingPane?
local function deserialize_floating(saved, pty_lookup, remap)
    if not saved or not saved.pane then
        return nil
    end
    local pty = pty_lookup(saved.pane.pty_id)
    if not pty then
        return nil
    end
    local new_id = pty:id()
    if remap and saved.pane.id then
        remap[saved.pane.id] = new_id
    end
    return {
        pane = {
            type = "pane",
            id = new_id,
            pty = pty,
        },
        visible = saved.visible or false,
    }
end

-- --- Layout Functions ---

---Count the number of panes in a layout node definition
---@param node PriseLayoutNode
---@return number
local function count_layout_panes(node)
    if node.type == "pane" then
        return 1
    elseif node.type == "split" then
        local count = 0
        for _, child in ipairs(node.children) do
            count = count + count_layout_panes(child)
        end
        return count
    end
    return 0
end

---Count total panes in a layout (all tabs + floating panes)
---@param layout PriseLayout
---@return number
local function count_layout_total_panes(layout)
    local count = 0
    for _, tab in ipairs(layout.tabs) do
        count = count + count_layout_panes(tab.root)
        if tab.floating and tab.floating.pane then
            count = count + 1
        end
    end
    return count
end

---Build a pending layout structure from a layout definition
---@param layout PriseLayout
---@return table pending_layout
local function build_pending_layout(layout)
    local pending = {
        layout = layout,
        panes_needed = count_layout_total_panes(layout),
        panes_received = 0,
        pty_queue = {},
        tabs_built = {},
    }
    return pending
end

---Assign a PTY to the next slot in a layout node, building the tree
---@param node PriseLayoutNode
---@param pty_queue Pty[]
---@param queue_idx number
---@return Node?, number new_queue_idx, string? error
local function build_node_from_layout(node, pty_queue, queue_idx)
    assert(node and type(node) == "table", "build_node_from_layout: node must be a table")
    assert(
        node.type == "pane" or node.type == "split",
        "build_node_from_layout: invalid node.type: " .. tostring(node.type)
    )

    if node.type == "pane" then
        local pty = pty_queue[queue_idx]
        if not pty then
            return nil, queue_idx, "no_pty_for_pane"
        end
        ---@type Pane
        local pane = {
            type = "pane",
            id = pty:id(),
            pty = pty,
            ratio = node.ratio,
        }
        return pane, queue_idx + 1, nil
    end

    -- node.type == "split"
    ---@type Node[]
    local children = {}
    local idx = queue_idx
    for _, child_def in ipairs(node.children or {}) do
        local child_node, new_idx, err = build_node_from_layout(child_def, pty_queue, idx)
        if not child_node then
            return nil, idx, err or "failed_child"
        end
        table.insert(children, child_node)
        idx = new_idx
    end
    if #children == 0 then
        return nil, idx, "empty_split"
    elseif #children == 1 then
        children[1].ratio = node.ratio
        return children[1], idx, nil
    end
    local split_id = state.next_split_id
    state.next_split_id = state.next_split_id + 1
    ---@type Split
    local split = {
        type = "split",
        split_id = split_id,
        direction = node.direction,
        ratio = node.ratio,
        children = children,
    }
    return split, idx, nil
end

---Close newly spawned PTYs on layout failure
---@param pty_queue Pty[]
---@param start_idx number
local function cleanup_new_ptys(pty_queue, start_idx)
    for i = start_idx, #pty_queue do
        local pty = pty_queue[i]
        if pty and pty.close then
            pty:close()
        end
    end
end

---Build a floating pane from layout definition
---@param floating_def table The floating definition from layout
---@param pty Pty The PTY for the floating pane
---@return FloatingPane
local function build_floating_pane(floating_def, pty)
    return {
        pane = {
            type = "pane",
            id = pty:id(),
            pty = pty,
        },
        visible = floating_def.visible ~= false,
    }
end

---Close all PTYs in existing tabs
---@param tabs Tab[]
local function close_old_tabs(tabs)
    for _, tab in ipairs(tabs) do
        local panes = collect_panes(tab.root, {})
        for _, pane in ipairs(panes) do
            if pane.pty and pane.pty.close then
                pane.pty:close()
            end
        end
        if tab.floating and tab.floating.pane and tab.floating.pane.pty and tab.floating.pane.pty.close then
            tab.floating.pane.pty:close()
        end
    end
end

---Build tabs from layout definition
---@param layout PriseLayout
---@param pty_queue Pty[]
---@return Tab[]? new_tabs
---@return number new_floating_width
---@return number new_floating_height
---@return boolean new_floating_visible
---@return number queue_idx Final queue index (for verification)
local function build_tabs_from_layout(layout, pty_queue)
    local new_tabs = {}
    local queue_idx = 1
    ---@type number
    local new_floating_width = state.floating.width
    ---@type number
    local new_floating_height = state.floating.height
    ---@type boolean
    local new_floating_visible = state.floating.visible

    for tab_index, tab_def in ipairs(layout.tabs) do
        local root, new_idx, err = build_node_from_layout(tab_def.root, pty_queue, queue_idx)
        if not root then
            prise.log.error(string.format("Layout: failed to build tab %d: %s", tab_index, err or "unknown"))
            cleanup_new_ptys(pty_queue, queue_idx)
            return nil, new_floating_width, new_floating_height, new_floating_visible, queue_idx
        end
        queue_idx = new_idx

        ---@type Tab
        local tab = {
            id = tab_index,
            title = tab_def.title,
            root = root,
            last_focused_id = root and (is_pane(root) and root.id or get_first_leaf(root) and get_first_leaf(root).id),
        }

        if tab_def.floating and tab_def.floating.pane then
            local floating_pty = pty_queue[queue_idx]
            if floating_pty then
                queue_idx = queue_idx + 1
                tab.floating = build_floating_pane(tab_def.floating, floating_pty)
                new_floating_width = tab_def.floating.width or new_floating_width
                new_floating_height = tab_def.floating.height or new_floating_height
                new_floating_visible = tab.floating.visible
            end
        end

        table.insert(new_tabs, tab)
    end

    return new_tabs, new_floating_width, new_floating_height, new_floating_visible, queue_idx
end

---Finalize a pending layout once all PTYs have been received
---@param pending table
local function finalize_layout(pending)
    assert(pending and pending.layout, "finalize_layout: missing pending layout")
    local layout = pending.layout
    local pty_queue = pending.pty_queue or {}

    -- Validate pane count before any destructive operations
    local needed = count_layout_total_panes(layout)
    if needed ~= #pty_queue then
        prise.log.error(string.format("Layout: pane count mismatch (layout=%d, ptys=%d)", needed, #pty_queue))
        cleanup_new_ptys(pty_queue, 1)
        state.pending_layout = nil
        return
    end

    -- Build new tab structures in memory first (before destroying old state)
    local new_tabs, new_floating_width, new_floating_height, new_floating_visible, queue_idx =
        build_tabs_from_layout(layout, pty_queue)
    if not new_tabs then
        state.pending_layout = nil
        return
    end
    local floating_width = new_floating_width or state.floating.width
    local floating_height = new_floating_height or state.floating.height
    local floating_visible = new_floating_visible
    if floating_visible == nil then
        floating_visible = state.floating.visible
    end

    -- Verify we used all PTYs
    if queue_idx ~= #pty_queue + 1 then
        prise.log.error(string.format("Layout: PTY mismatch after build (used %d of %d)", queue_idx - 1, #pty_queue))
        cleanup_new_ptys(pty_queue, queue_idx)
        state.pending_layout = nil
        return
    end

    -- Build succeeded - now safely close old PTYs/tabs
    close_old_tabs(state.tabs)

    -- Swap in new state
    -- LuaLS treats the secondary return values as optional because the failure path
    -- above returns `nil` for the whole tuple. Narrow them after the `new_tabs` guard.
    ---@cast new_floating_width number
    ---@cast new_floating_height number
    ---@cast new_floating_visible boolean
    state.tabs = new_tabs
    state.next_tab_id = #new_tabs + 1
    state.floating.width = floating_width
    state.floating.height = floating_height
    state.floating.visible = floating_visible
    state.zoomed_pane_id = nil

    -- Set active tab
    state.active_tab = layout.active_tab or 1
    if state.active_tab > #state.tabs then
        state.active_tab = #state.tabs
    end
    if state.active_tab < 1 and #state.tabs > 0 then
        state.active_tab = 1
    end

    -- Set focus to first pane in active tab
    local active_tab = state.tabs[state.active_tab]
    if active_tab and active_tab.root then
        local first = get_first_leaf(active_tab.root)
        if first then
            state.focused_id = first.id
            update_pty_focus(nil, state.focused_id)
        end
    end

    state.pending_layout = nil
    prise.request_frame()
    prise.save()
end

---Expand ~ to home directory in a path and validate it exists
---@param path? string
---@return string?
local function expand_path(path)
    if path == nil then
        return nil
    end
    assert(type(path) == "string", "expand_path: path must be a string")

    local expanded = path
    if path:sub(1, 1) == "~" then
        local home = os.getenv("HOME")
        if home then
            expanded = home .. path:sub(2)
        else
            prise.log.warn("Layout: HOME not set, cannot expand ~")
            return nil
        end
    end

    -- Check if path exists as a file
    local f = io.open(expanded, "r")
    if f then
        f:close()
        return expanded
    end

    -- Probe "path/." so we can recognize directories without shelling out.
    local dir_probe = io.open(expanded .. "/.", "r")
    if dir_probe then
        dir_probe:close()
        return expanded
    end

    prise.log.warn("Layout: cwd does not exist: " .. expanded)
    return nil
end

---Spawn PTYs for a layout node recursively
---@param node PriseLayoutNode
local function spawn_for_layout_node(node)
    assert(node and type(node) == "table", "spawn_for_layout_node: node must be a table")
    if node.type == "pane" then
        prise.spawn({ cwd = expand_path(node.cwd), cmd = node.cmd })
    elseif node.type == "split" then
        for _, child in ipairs(node.children or {}) do
            spawn_for_layout_node(child)
        end
    end
end

---Apply a layout by name
---@param layout_name string
---@return boolean
local function apply_layout(layout_name)
    assert(type(layout_name) == "string", "apply_layout: layout_name must be a string")

    if state.pending_layout then
        prise.log.warn("Layout already pending")
        return false
    end

    local layout = config.layouts[layout_name]
    if not layout then
        prise.log.warn("Layout not found: " .. layout_name)
        return false
    end

    -- Validate layout structure
    assert(type(layout) == "table", "Layout must be a table")
    assert(layout.tabs and #layout.tabs > 0, "Layout must have at least one tab")

    local total_panes = count_layout_total_panes(layout)
    if total_panes == 0 then
        prise.log.warn("Layout has no panes: " .. layout_name)
        return false
    end

    -- Build pending layout state
    state.pending_layout = build_pending_layout(layout)

    -- Spawn all needed PTYs
    for _, tab_def in ipairs(layout.tabs) do
        assert(tab_def.root, "Layout tab must have a root node")
        spawn_for_layout_node(tab_def.root)

        -- Spawn floating pane if defined
        if tab_def.floating and tab_def.floating.pane then
            prise.spawn({
                cwd = expand_path(tab_def.floating.pane.cwd),
                cmd = tab_def.floating.pane.cmd,
            })
        end
    end

    return true
end

---Get sorted list of layout names
---@return string[]
local function get_layout_names()
    local names = {}
    for name, _ in pairs(config.layouts) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

---Open the layout picker
local function open_layout_picker()
    local names = get_layout_names()
    if #names == 0 then
        prise.log.warn("No layouts defined")
        return
    end
    state.layout_picker.visible = true
    state.layout_picker.selected = 1
    state.layout_picker.scroll_offset = 0
    state.layout_picker.regions = {}
    prise.request_frame()
end

---Close the layout picker
local function close_layout_picker()
    state.layout_picker.visible = false
    prise.request_frame()
end

---Execute the selected layout
local function execute_selected_layout()
    local names = get_layout_names()
    local idx = state.layout_picker.selected
    if idx >= 1 and idx <= #names then
        local layout_name = names[idx]
        close_layout_picker()
        apply_layout(layout_name)
    end
end

local MIN_PANE_SHARE = 0.05

---Get the effective ratio for a child in a split
---@param split Split
---@param idx number
---@return number
local function effective_ratio(split, idx)
    local n = #split.children
    return split.children[idx].ratio or (1.0 / n)
end

---Adjust the ratios of two adjacent siblings, keeping their combined share constant
---@param split Split
---@param left_idx number
---@param right_idx number
---@param delta number Amount to add to left child (negative grows right child)
local function adjust_pair(split, left_idx, right_idx, delta)
    local left_r = effective_ratio(split, left_idx)
    local right_r = effective_ratio(split, right_idx)
    local total = left_r + right_r

    if total < 2 * MIN_PANE_SHARE then
        return
    end

    local new_left = left_r + delta

    -- Clamp so each keeps at least MIN_PANE_SHARE
    if new_left < MIN_PANE_SHARE then
        new_left = MIN_PANE_SHARE
    end
    if new_left > total - MIN_PANE_SHARE then
        new_left = total - MIN_PANE_SHARE
    end

    local new_right = total - new_left

    split.children[left_idx].ratio = new_left
    split.children[right_idx].ratio = new_right
end

---@param dimension "width"|"height"
---@param delta_ratio number
local function resize_pane(dimension, delta_ratio)
    local root = get_active_root()
    if not state.focused_id or not root then
        return
    end

    local path = find_node_path(root, state.focused_id)
    if not path then
        return
    end

    local target_split_dir = (dimension == "width") and "row" or "col"

    -- Traverse up to find a split of the correct direction
    local parent_split = nil
    local child_idx = nil

    for i = #path - 1, 1, -1 do
        if path[i].type == "split" and path[i].direction == target_split_dir then
            parent_split = path[i]
            local node = path[i + 1]

            -- Find index of current node in parent's children
            for k, c in ipairs(parent_split.children) do
                if c == node then
                    child_idx = k
                    break
                end
            end
            break
        end
    end

    if not parent_split or not child_idx then
        return
    end

    local num_children = #parent_split.children

    -- Use pairwise adjustment to enable resizing in both directions from any focused pane.
    if delta_ratio < 0 then
        -- Negative delta: try to move left boundary (focused pane may grow by taking from left)
        if child_idx > 1 then
            -- Left neighbor exists: adjust the left boundary (left shrinks, focused grows)
            adjust_pair(parent_split, child_idx - 1, child_idx, delta_ratio) -- delta_ratio is negative
        elseif child_idx < num_children then
            -- No left neighbor but right exists: adjust right boundary to achieve opposite effect (focused shrinks, right grows)
            -- Since we want a "left resize" effect but no left neighbor, we make focused shrink instead
            adjust_pair(parent_split, child_idx, child_idx + 1, delta_ratio) -- delta_ratio is negative, so focused shrinks, right grows
        else
            return
        end
    else
        -- Positive delta: try to move right boundary (focused pane may grow by taking from right)
        if child_idx < num_children then
            -- Right neighbor exists: adjust the right boundary (focused grows, right shrinks)
            adjust_pair(parent_split, child_idx, child_idx + 1, delta_ratio) -- delta_ratio is positive
        elseif child_idx > 1 then
            -- No right neighbor but left exists: adjust left boundary to achieve opposite effect (left shrinks, focused grows)
            -- Since we want a "right resize" effect but no right neighbor, we make left shrink to grow focused
            adjust_pair(parent_split, child_idx - 1, child_idx, delta_ratio) -- delta_ratio is positive, so left shrinks, focused grows
        else
            return
        end
    end

    prise.request_frame()
    prise.save()
end

---@param direction "left"|"right"|"up"|"down"
---@param wrap? boolean
local function move_focus(direction, wrap)
    local root = get_active_root()
    if not state.focused_id or not root then
        return
    end

    local path = find_node_path(root, state.focused_id)
    if not path then
        return
    end

    -- "left"/"right" implies moving along "horizontal"
    -- "up"/"down" implies moving along "vertical"
    local target_split_type = (direction == "left" or direction == "right") and "row" or "col"
    local forward = (direction == "right" or direction == "down")

    local sibling_node = nil

    -- Traverse up the path to find a split of the correct type where we can move
    -- path is [root, ..., parent, leaf]
    for i = #path - 1, 1, -1 do
        local node = path[i]
        local child = path[i + 1]

        if node.type == "split" and node.direction == target_split_type then
            -- Find index of child
            local idx = 0
            for k, c in ipairs(node.children) do
                if c == child then
                    idx = k
                    break
                end
            end

            if forward then
                if idx < #node.children then
                    sibling_node = node.children[idx + 1]
                    break
                end
            else
                if idx > 1 then
                    sibling_node = node.children[idx - 1]
                    break
                end
            end
        end
    end

    -- Wrapping fallback: find outermost matching split, pick opposite edge
    if not sibling_node and wrap then
        for i = 1, #path - 1 do
            local node = path[i]
            if node.type == "split" and node.direction == target_split_type then
                if forward then
                    sibling_node = node.children[1]
                else
                    sibling_node = node.children[#node.children]
                end
                break
            end
        end
    end

    if sibling_node then
        -- Found a sibling tree/pane. Find the closest leaf.
        ---@type Pane?
        local target_leaf
        if forward then
            target_leaf = get_first_leaf(sibling_node)
        else
            target_leaf = get_last_leaf(sibling_node)
        end

        if target_leaf and target_leaf.id ~= state.focused_id then
            local old_id = state.focused_id
            state.focused_id = target_leaf.id
            update_pty_focus(old_id, state.focused_id)
            update_cached_git_branch()
            prise.request_frame()
        end
    end
end

---Find the leaf in `direction` from the focused pane, or nil when there
---is nowhere to go (single pane, or at the layout edge). Walks the same
---path as move_focus but returns the target leaf instead of mutating
---focus state, so it's reusable for any operation that needs a
---directional neighbor.
---@param direction "left"|"right"|"up"|"down"
---@return Pane?
local function find_directional_leaf(direction)
    local root = get_active_root()
    if not state.focused_id or not root then
        return nil
    end

    local path = find_node_path(root, state.focused_id)
    if not path then
        return nil
    end

    local target_split_type = (direction == "left" or direction == "right") and "row" or "col"
    local forward = (direction == "right" or direction == "down")

    local sibling_node = nil

    for i = #path - 1, 1, -1 do
        local node = path[i]
        local child = path[i + 1]

        if node.type == "split" and node.direction == target_split_type then
            local idx = 0
            for k, c in ipairs(node.children) do
                if c == child then
                    idx = k
                    break
                end
            end

            if forward then
                if idx < #node.children then
                    sibling_node = node.children[idx + 1]
                    break
                end
            else
                if idx > 1 then
                    sibling_node = node.children[idx - 1]
                    break
                end
            end
        end
    end

    if not sibling_node then
        return nil
    end

    if forward then
        return get_first_leaf(sibling_node)
    else
        return get_last_leaf(sibling_node)
    end
end

---Swap the focused pane's content with the directional neighbor. The
---two leaves trade `(id, pty)` so focus follows content: state.focused_id
---is unchanged, but the leaf carrying that id now sits in the neighbor's
---former position. Per-position state on the leaf (`ratio`) stays put.
---@param direction "left"|"right"|"up"|"down"
local function swap_pane(direction)
    local root = get_active_root()
    if not state.focused_id or not root then
        return
    end

    local source_path = find_node_path(root, state.focused_id)
    if not source_path then
        return
    end
    local source_leaf = source_path[#source_path]

    local target_leaf = find_directional_leaf(direction)
    if not target_leaf or target_leaf.id == source_leaf.id then
        return
    end

    source_leaf.id, target_leaf.id = target_leaf.id, source_leaf.id
    source_leaf.pty, target_leaf.pty = target_leaf.pty, source_leaf.pty

    prise.request_frame()
    prise.save()
end

local function get_tab_display_name(tab_index)
    local tab = state.tabs[tab_index]
    if not tab then
        return "Tab " .. tab_index
    end
    if tab.title and tab.title ~= "" then
        return tab.title
    end
    return "Tab " .. tab_index
end

local function open_rename_tab()
    if not state.rename_tab.input then
        state.rename_tab.input = prise.create_text_input()
    end
    local tab = get_active_tab()
    local current_title = (tab and tab.title) or ""
    state.rename_tab.input:clear()
    state.rename_tab.input:insert(current_title)
    state.rename_tab.visible = true
    prise.request_frame()
end

local function close_rename_tab()
    state.rename_tab.visible = false
    prise.request_frame()
end

local function execute_rename_tab()
    if not state.rename_tab.input then
        return
    end
    local new_title = state.rename_tab.input:text()
    local tab = get_active_tab()
    if tab then
        -- If empty, clear title to show index number
        if new_title == "" then
            tab.title = nil
        else
            tab.title = new_title
        end
        prise.save() -- Auto-save on tab renamed
    end
    close_rename_tab()
end

-- Platform-dependent key prefix for shortcuts
local key_prefix = prise.platform == "macos" and "󰘳 +k" or "Super+k"

---Forward declaration for open_rename
---@type fun()
local open_rename

---Forward declaration for open_session_picker
---@type fun()
local open_session_picker

---Toggle a named overlay: spawn if new, show/hide if existing
---@param name string Overlay name (e.g. "floating", "lazygit")
toggle_overlay = function(name)
    local cfg = config.overlays[name]
    local ost = state.overlay_state[name]
    if not cfg or not ost then
        return
    end

    local tab = get_active_tab()
    if not tab then
        return
    end

    tab.overlays = tab.overlays or {}

    if not tab.overlays[name] then
        -- No overlay pane exists yet — spawn one (skip if already pending)
        if ost.pending then
            return
        end
        ost.pending = true
        local pty = get_focused_pty()
        local spawn_cmd = cfg.cmd
        if spawn_cmd and not cfg.shell then
            spawn_cmd = "exec " .. spawn_cmd
        end
        prise.spawn({ cwd = pty and pty:cwd(), cmd = spawn_cmd })
    else
        -- Toggle visibility
        local overlay = tab.overlays[name]
        overlay.visible = not overlay.visible
        if overlay.visible then
            state.active_overlay_name = name
        else
            -- Clear active if we just hid it
            if state.active_overlay_name == name then
                state.active_overlay_name = nil
            end
        end
        prise.request_frame()
    end
end

---Command palette commands
---@type Command[]
local commands = {
    {
        name = "Split Horizontal",
        shortcut = key_prefix .. " v",
        action = function()
            local pty = get_focused_pty()
            state.pending_split = { direction = "row" }
            prise.spawn({ cwd = pty and pty:cwd() })
        end,
    },
    {
        name = "Split Vertical",
        shortcut = key_prefix .. " s",
        action = function()
            local pty = get_focused_pty()
            state.pending_split = { direction = "col" }
            prise.spawn({ cwd = pty and pty:cwd() })
        end,
    },
    {
        name = "Split Auto",
        shortcut = key_prefix .. " Enter",
        action = function()
            local pty = get_focused_pty()
            state.pending_split = { direction = get_auto_split_direction() }
            prise.spawn({ cwd = pty and pty:cwd() })
        end,
    },
    {
        name = "Focus Left",
        shortcut = key_prefix .. " h",
        action = function()
            move_focus("left")
        end,
    },
    {
        name = "Focus Right",
        shortcut = key_prefix .. " l",
        action = function()
            move_focus("right")
        end,
    },
    {
        name = "Focus Up",
        shortcut = key_prefix .. " k",
        action = function()
            move_focus("up")
        end,
    },
    {
        name = "Focus Down",
        shortcut = key_prefix .. " j",
        action = function()
            move_focus("down")
        end,
    },
    {
        name = "Focus Left (Wrap)",
        action = function()
            move_focus("left", true)
        end,
    },
    {
        name = "Focus Right (Wrap)",
        action = function()
            move_focus("right", true)
        end,
    },
    {
        name = "Focus Up (Wrap)",
        action = function()
            move_focus("up", true)
        end,
    },
    {
        name = "Focus Down (Wrap)",
        action = function()
            move_focus("down", true)
        end,
    },
    {
        name = "Close Pane",
        shortcut = key_prefix .. " w",
        action = function()
            local root = get_active_root()
            local path = state.focused_id and find_node_path(root, state.focused_id)
            if path then
                local pane = path[#path]
                pane.pty:close()
                local was_last = remove_pane_by_id(pane.id)
                if not was_last then
                    prise.save()
                end
            end
        end,
    },
    {
        name = "Toggle Zoom",
        shortcut = key_prefix .. " z",
        action = function()
            if state.zoomed_pane_id then
                state.zoomed_pane_id = nil
            elseif state.focused_id then
                state.zoomed_pane_id = state.focused_id
            end
            prise.request_frame()
        end,
    },
    {
        name = "Break Pane",
        action = function()
            local focused_id = state.focused_id
            if not focused_id then
                prise.log.warn("break_pane: no focused pane")
                return
            end
            M.update({ type = "break_pane", data = { pty_id = focused_id, focus = true } })
        end,
    },
    {
        name = "New Tab",
        shortcut = key_prefix .. " t",
        action = function()
            local pty = get_focused_pty()
            state.pending_new_tab = true
            prise.spawn({ cwd = pty and pty:cwd() })
        end,
    },
    {
        name = "Close Tab",
        shortcut = key_prefix .. " c",
        action = function()
            close_current_tab()
        end,
    },
    {
        name = "Rename Tab",
        shortcut = key_prefix .. " r",
        action = function()
            open_rename_tab()
        end,
    },
    {
        name = "Next Tab",
        shortcut = key_prefix .. " n",
        action = function()
            if #state.tabs > 1 then
                local next_idx = state.active_tab % #state.tabs + 1
                set_active_tab_index(next_idx)
            end
        end,
    },
    {
        name = "Previous Tab",
        shortcut = key_prefix .. " p",
        action = function()
            if #state.tabs > 1 then
                local prev_idx = (state.active_tab - 2 + #state.tabs) % #state.tabs + 1
                set_active_tab_index(prev_idx)
            end
        end,
    },
    {
        name = "Swap Tab Left",
        action = function()
            if state.active_tab > 1 then
                swap_tabs(state.active_tab, state.active_tab - 1)
            end
        end,
        visible = function()
            return #state.tabs > 1
        end,
    },
    {
        name = "Swap Tab Right",
        action = function()
            if state.active_tab < #state.tabs then
                swap_tabs(state.active_tab, state.active_tab + 1)
            end
        end,
        visible = function()
            return #state.tabs > 1
        end,
    },
    {
        name = "Swap Tab with Index",
        action = function()
            if #state.tabs <= 1 then
                return
            end
            -- Open a text input for the user to specify the tab index
            state.swap_with_index = {
                visible = true,
                input = prise.create_text_input(),
                target_index = nil,
            }
            prise.request_frame()
        end,
        visible = function()
            return #state.tabs > 1
        end,
    },
    {
        name = "Detach Session",
        shortcut = key_prefix .. " d",
        action = function()
            detach_session()
        end,
    },
    {
        name = "Rename Session",
        action = function()
            open_rename()
        end,
    },
    {
        name = "Switch Session",
        shortcut = key_prefix .. " S",
        action = function()
            open_session_picker()
        end,
    },
    {
        name = "Layouts",
        shortcut = key_prefix .. " o",
        action = function()
            open_layout_picker()
        end,
        visible = function()
            return next(config.layouts) ~= nil
        end,
    },
    {
        name = "Quit",
        shortcut = key_prefix .. " q",
        action = function()
            detach_session()
        end,
    },
    {
        name = "Resize Left",
        shortcut = key_prefix .. " H",
        action = function()
            resize_pane("width", -RESIZE_STEP)
        end,
    },
    {
        name = "Resize Right",
        shortcut = key_prefix .. " L",
        action = function()
            resize_pane("width", RESIZE_STEP)
        end,
    },
    {
        name = "Resize Up",
        shortcut = key_prefix .. " K",
        action = function()
            resize_pane("height", -RESIZE_STEP)
        end,
    },
    {
        name = "Resize Down",
        shortcut = key_prefix .. " J",
        action = function()
            resize_pane("height", RESIZE_STEP)
        end,
    },
    {
        name = function()
            return get_tab_display_name(1)
        end,
        shortcut = key_prefix .. " 1",
        action = function()
            set_active_tab_index(1)
        end,
        visible = function()
            return #state.tabs >= 1
        end,
    },
    {
        name = function()
            return get_tab_display_name(2)
        end,
        shortcut = key_prefix .. " 2",
        action = function()
            set_active_tab_index(2)
        end,
        visible = function()
            return #state.tabs >= 2
        end,
    },
    {
        name = function()
            return get_tab_display_name(3)
        end,
        shortcut = key_prefix .. " 3",
        action = function()
            set_active_tab_index(3)
        end,
        visible = function()
            return #state.tabs >= 3
        end,
    },
    {
        name = function()
            return get_tab_display_name(4)
        end,
        shortcut = key_prefix .. " 4",
        action = function()
            set_active_tab_index(4)
        end,
        visible = function()
            return #state.tabs >= 4
        end,
    },
    {
        name = function()
            return get_tab_display_name(5)
        end,
        shortcut = key_prefix .. " 5",
        action = function()
            set_active_tab_index(5)
        end,
        visible = function()
            return #state.tabs >= 5
        end,
    },
    {
        name = function()
            return get_tab_display_name(6)
        end,
        shortcut = key_prefix .. " 6",
        action = function()
            set_active_tab_index(6)
        end,
        visible = function()
            return #state.tabs >= 6
        end,
    },
    {
        name = function()
            return get_tab_display_name(7)
        end,
        shortcut = key_prefix .. " 7",
        action = function()
            set_active_tab_index(7)
        end,
        visible = function()
            return #state.tabs >= 7
        end,
    },
    {
        name = function()
            return get_tab_display_name(8)
        end,
        shortcut = key_prefix .. " 8",
        action = function()
            set_active_tab_index(8)
        end,
        visible = function()
            return #state.tabs >= 8
        end,
    },
    {
        name = "Tab 9",
        shortcut = key_prefix .. " 9",
        action = function()
            set_active_tab_index(9)
        end,
        visible = function()
            return #state.tabs >= 9
        end,
    },
    {
        name = "Tab 10",
        shortcut = key_prefix .. " 0",
        action = function()
            set_active_tab_index(10)
        end,
        visible = function()
            return #state.tabs >= 10
        end,
    },
    {
        name = "Toggle Floating Pane",
        shortcut = key_prefix .. " f",
        action = function()
            action_handlers.floating_toggle()
        end,
    },
}

-- Action handlers for keybind system
-- Maps action names (from Action enum) to handler functions
action_handlers = {
    split_horizontal = function()
        local pty = get_focused_pty()
        state.pending_split = { direction = "row" }
        prise.spawn({ cwd = pty and pty:cwd() })
    end,
    split_vertical = function()
        local pty = get_focused_pty()
        state.pending_split = { direction = "col" }
        prise.spawn({ cwd = pty and pty:cwd() })
    end,
    split_auto = function()
        local pty = get_focused_pty()
        state.pending_split = { direction = get_auto_split_direction() }
        prise.spawn({ cwd = pty and pty:cwd() })
    end,
    focus_left = function()
        move_focus("left")
    end,
    focus_right = function()
        move_focus("right")
    end,
    focus_up = function()
        move_focus("up")
    end,
    focus_down = function()
        move_focus("down")
    end,
    focus_left_wrap = function()
        move_focus("left", true)
    end,
    focus_right_wrap = function()
        move_focus("right", true)
    end,
    focus_up_wrap = function()
        move_focus("up", true)
    end,
    focus_down_wrap = function()
        move_focus("down", true)
    end,
    close_pane = function()
        local root = get_active_root()
        local path = state.focused_id and find_node_path(root, state.focused_id)
        if path then
            local pane = path[#path]
            pane.pty:close()
            local was_last = remove_pane_by_id(pane.id)
            if not was_last then
                prise.save()
            end
        end
    end,
    toggle_zoom = function()
        if state.zoomed_pane_id then
            state.zoomed_pane_id = nil
        elseif state.focused_id then
            state.zoomed_pane_id = state.focused_id
        end
        prise.request_frame()
    end,
    break_pane = function()
        local focused_id = state.focused_id
        if not focused_id then
            prise.log.warn("break_pane: no focused pane")
            return
        end
        M.update({ type = "break_pane", data = { pty_id = focused_id, focus = true } })
    end,
    swap_pane_left = function()
        swap_pane("left")
    end,
    swap_pane_right = function()
        swap_pane("right")
    end,
    swap_pane_up = function()
        swap_pane("up")
    end,
    swap_pane_down = function()
        swap_pane("down")
    end,
    new_tab = function()
        local pty = get_focused_pty()
        state.pending_new_tab = true
        prise.spawn({ cwd = pty and pty:cwd() })
    end,
    close_tab = function()
        close_current_tab()
    end,
    rename_tab = function()
        open_rename_tab()
    end,
    next_tab = function()
        if #state.tabs > 1 then
            local next_idx = state.active_tab % #state.tabs + 1
            set_active_tab_index(next_idx)
        end
    end,
    previous_tab = function()
        if #state.tabs > 1 then
            local prev_idx = (state.active_tab - 2 + #state.tabs) % #state.tabs + 1
            set_active_tab_index(prev_idx)
        end
    end,
    swap_tab_left = function()
        if state.active_tab > 1 then
            swap_tabs(state.active_tab, state.active_tab - 1)
        end
    end,
    swap_tab_right = function()
        if state.active_tab < #state.tabs then
            swap_tabs(state.active_tab, state.active_tab + 1)
        end
    end,
    swap_tab_left_wrap = function()
        if #state.tabs < 2 then
            return
        end
        if state.active_tab > 1 then
            swap_tabs(state.active_tab, state.active_tab - 1)
        else
            -- Rotate: active tab walks off the left, reappears at the right.
            -- Relative order of the non-active tabs is preserved.
            local tab = table.remove(state.tabs, 1)
            table.insert(state.tabs, tab)
            state.active_tab = #state.tabs
            prise.request_frame()
            prise.save()
        end
    end,
    swap_tab_right_wrap = function()
        if #state.tabs < 2 then
            return
        end
        if state.active_tab < #state.tabs then
            swap_tabs(state.active_tab, state.active_tab + 1)
        else
            -- Rotate: active tab walks off the right, reappears at the left.
            local tab = table.remove(state.tabs)
            table.insert(state.tabs, 1, tab)
            state.active_tab = 1
            prise.request_frame()
            prise.save()
        end
    end,
    tab_1 = function()
        set_active_tab_index(1)
    end,
    tab_2 = function()
        set_active_tab_index(2)
    end,
    tab_3 = function()
        set_active_tab_index(3)
    end,
    tab_4 = function()
        set_active_tab_index(4)
    end,
    tab_5 = function()
        set_active_tab_index(5)
    end,
    tab_6 = function()
        set_active_tab_index(6)
    end,
    tab_7 = function()
        set_active_tab_index(7)
    end,
    tab_8 = function()
        set_active_tab_index(8)
    end,
    tab_9 = function()
        set_active_tab_index(9)
    end,
    tab_10 = function()
        set_active_tab_index(10)
    end,
    resize_left = function()
        resize_pane("width", -RESIZE_STEP)
    end,
    resize_right = function()
        resize_pane("width", RESIZE_STEP)
    end,
    resize_up = function()
        resize_pane("height", -RESIZE_STEP)
    end,
    resize_down = function()
        resize_pane("height", RESIZE_STEP)
    end,
    detach_session = function()
        detach_session()
    end,
    rename_session = function()
        open_rename()
    end,
    switch_session = function()
        open_session_picker()
    end,
    quit = function()
        detach_session()
    end,
    floating_toggle = function()
        local tab = get_active_tab()
        if not tab then
            return
        end

        if not tab.floating then
            -- No floating pane created yet, spawn one
            state.floating.pending = true
            local pty = get_focused_pty()
            prise.spawn({ cwd = pty and pty:cwd() })
        else
            -- Toggle visibility
            tab.floating.visible = not tab.floating.visible
            prise.request_frame()
        end
    end,
    floating_increase_size = function()
        state.floating.width = math.min(state.floating.width + FLOATING_WIDTH_STEP, FLOATING_MAX_WIDTH)
        state.floating.height = math.min(state.floating.height + FLOATING_HEIGHT_STEP, FLOATING_MAX_HEIGHT)
        state.floating.resize_mode = true
        prise.request_frame()
    end,
    floating_decrease_size = function()
        state.floating.width = math.max(state.floating.width - FLOATING_WIDTH_STEP, FLOATING_MIN_WIDTH)
        state.floating.height = math.max(state.floating.height - FLOATING_HEIGHT_STEP, FLOATING_MIN_HEIGHT)
        state.floating.resize_mode = true
        prise.request_frame()
    end,
    layout_picker = function()
        open_layout_picker()
    end,
    -- command_palette is added after open_palette is defined
}

---@param query string
---@return Command[]
local function filter_commands(query)
    local results = {}
    for _, cmd in ipairs(commands) do
        local is_visible = not cmd.visible or cmd.visible()
        if is_visible then
            local cmd_name = cmd.name
            if type(cmd_name) == "function" then
                cmd_name = cmd_name()
            end
            if not query or query == "" or cmd_name:lower():find(query:lower(), 1, true) then
                table.insert(results, cmd)
            end
        end
    end
    return results
end

local function open_palette()
    if not state.palette.input then
        state.palette.input = prise.create_text_input()
    end
    state.palette.visible = true
    state.palette.selected = 1
    state.palette.scroll_offset = 0
    state.palette.input:clear()
    prise.request_frame()
end

-- Add command_palette handler now that open_palette is defined
action_handlers.command_palette = function()
    open_palette()
end

local function close_palette()
    state.palette.visible = false
    prise.request_frame()
end

local function execute_selected()
    local filtered = filter_commands(state.palette.input:text())
    if filtered[state.palette.selected] then
        close_palette()
        filtered[state.palette.selected].action()
    end
end

open_rename = function()
    if not state.rename.input then
        state.rename.input = prise.create_text_input()
    end
    local current_name = prise.get_session_name() or ""
    state.rename.input:clear()
    state.rename.input:insert(current_name)
    state.rename.visible = true
    prise.request_frame()
end

local function close_rename()
    state.rename.visible = false
    prise.request_frame()
end

local function execute_rename()
    local new_name = state.rename.input:text()
    if new_name and new_name ~= "" then
        local current_name = prise.get_session_name() or ""
        prise.rename_session(current_name, new_name)
    end
    close_rename()
end

open_session_picker = function()
    if not state.session_picker.input then
        state.session_picker.input = prise.create_text_input()
    end
    state.session_picker.input:clear()
    state.session_picker.sessions = prise.list_sessions() or {}
    state.session_picker.selected = 1
    state.session_picker.scroll_offset = 0
    state.session_picker.visible = true
    prise.request_frame()
end

local function close_session_picker()
    state.session_picker.visible = false
    prise.request_frame()
end

---Filter sessions by fuzzy matching the input text
---@param query string
---@return string[]
local function filter_sessions(query)
    if not query or query == "" then
        return state.session_picker.sessions
    end
    local lower_query = query:lower()
    local matches = {}
    for _, session in ipairs(state.session_picker.sessions) do
        if session:lower():find(lower_query, 1, true) then
            table.insert(matches, session)
        end
    end
    return matches
end

local function execute_session_switch()
    local query = state.session_picker.input:text()
    local filtered = filter_sessions(query)
    if #filtered == 0 then
        close_session_picker()
        return
    end
    local idx = state.session_picker.selected
    if idx >= 1 and idx <= #filtered then
        local target = filtered[idx]
        close_session_picker()
        prise.switch_session(target)
    end
end

local function open_session_rename()
    local query = state.session_picker.input:text()
    local filtered = filter_sessions(query)
    if #filtered == 0 then
        return
    end
    local idx = state.session_picker.selected
    if idx >= 1 and idx <= #filtered then
        local target = filtered[idx]
        state.session_picker.renaming = true
        state.session_picker.rename_target = target
        state.session_picker.input:clear()
        state.session_picker.input:insert(target)
        prise.request_frame()
    end
end

local function close_session_rename()
    state.session_picker.renaming = false
    state.session_picker.rename_target = nil
    state.session_picker.input:clear()
    state.session_picker.selected = 1
    state.session_picker.scroll_offset = 0
    -- Refresh the session list
    state.session_picker.sessions = prise.list_sessions() or {}
    prise.request_frame()
end

local function execute_session_rename()
    local new_name = state.session_picker.input:text()
    local target = state.session_picker.rename_target
    if new_name and new_name ~= "" and target and new_name ~= target then
        local ok, err = pcall(function()
            prise.rename_session(target, new_name)
        end)
        if not ok then
            prise.log.warn("Failed to rename session: " .. tostring(err))
        end
    end
    close_session_rename()
end

-- --- Main Functions ---

---@param event Event
function M.update(event)
    if event.type == "pty_attach" then
        prise.log.info("Lua: pty_attach received")
        ---@type Pty
        local pty = event.data.pty
        ---@type Pane
        local new_pane = { type = "pane", pty = pty, id = pty:id() }
        local old_focused_id = state.focused_id

        -- Apply default layout on first attach (no session restore)
        if #state.tabs == 0 and config.default_layout and not state.pending_layout then
            local applied = apply_layout(config.default_layout)
            if applied then
                if pty and pty.close then
                    pty:close()
                end
                return
            end
        end

        -- Check if we're building a layout
        if state.pending_layout then
            table.insert(state.pending_layout.pty_queue, pty)
            state.pending_layout.panes_received = state.pending_layout.panes_received + 1
            if state.pending_layout.panes_received >= state.pending_layout.panes_needed then
                finalize_layout(state.pending_layout)
            end
            return
        end

        -- Check if this PTY should be assigned to the floating pane
        if state.floating.pending then
            state.floating.pending = false
            local tab = get_active_tab()
            if tab then
                tab.floating = { pane = new_pane, visible = true }
            end
            prise.request_frame()
            return
        end

        local spawn_opts = state.pending_spawns[new_pane.id]
        local spawn_no_focus = spawn_opts and spawn_opts.no_focus
        state.pending_spawns[new_pane.id] = nil

        local new_tab_requested = (spawn_opts and spawn_opts.new_tab) or state.pending_new_tab
        state.pending_new_tab = false

        if new_tab_requested then
            -- Create a new tab with this pane
            local tab_id = state.next_tab_id
            state.next_tab_id = tab_id + 1
            ---@type Tab
            local new_tab = {
                id = tab_id,
                root = new_pane,
                last_focused_id = new_pane.id,
            }
            table.insert(state.tabs, new_tab)
            if not spawn_no_focus then
                set_active_tab_index(#state.tabs)
            end
        elseif #state.tabs == 0 then
            -- First terminal - create first tab
            local tab_id = state.next_tab_id
            state.next_tab_id = tab_id + 1
            ---@type Tab
            local new_tab = {
                id = tab_id,
                root = new_pane,
                last_focused_id = new_pane.id,
            }
            table.insert(state.tabs, new_tab)
            state.active_tab = 1
            state.focused_id = new_pane.id
        else
            state.zoomed_pane_id = nil -- Unzoom to reveal new split pane
            -- Insert into active tab's tree
            local tab = get_active_tab()
            if not tab then
                return
            end

            local direction = (state.pending_split and state.pending_split.direction) or "row"

            if state.focused_id then
                tab.root = insert_split_recursive(tab.root, state.focused_id, new_pane, direction)
            else
                -- Fallback
                if is_split(tab.root) then
                    table.insert(tab.root.children, new_pane)
                else
                    local split_id = state.next_split_id
                    state.next_split_id = state.next_split_id + 1
                    tab.root = {
                        type = "split",
                        split_id = split_id,
                        direction = direction,
                        children = { tab.root, new_pane },
                    }
                end
            end

            state.focused_id = new_pane.id
            state.pending_split = nil
        end
        -- Skip focus change for programmatic spawns (no focus steal)
        if spawn_no_focus then
            state.focused_id = old_focused_id
        end
        update_pty_focus(old_focused_id, state.focused_id)
        prise.request_frame()
        prise.save() -- Auto-save on pane added

        -- Apply any queued title rename from spawn placement
        local rename = state.pending_title_renames[new_pane.id]
        if rename then
            local _, tab = find_tab_for_pane(new_pane.id)
            if tab then
                tab.title = rename
                prise.save()
            end
            state.pending_title_renames[new_pane.id] = nil
        end
    elseif event.type == "key_press" then
        -- Handle command palette
        if state.palette.visible then
            ---@type string
            local k = event.data.key
            local filtered = filter_commands(state.palette.input:text())

            prise.log.debug(
                "palette key: "
                    .. tostring(k)
                    .. " len="
                    .. #k
                    .. " ctrl="
                    .. tostring(event.data.ctrl)
                    .. " super="
                    .. tostring(event.data.super)
            )

            if k == "Escape" then
                close_palette()
                return
            elseif k == "Enter" then
                execute_selected()
                return
            elseif k == "ArrowUp" or (k == "p" and event.data.ctrl) then
                if state.palette.selected > 1 then
                    state.palette.selected = state.palette.selected - 1
                    prise.request_frame()
                end
                return
            elseif k == "ArrowDown" or (k == "n" and event.data.ctrl) then
                if state.palette.selected < #filtered then
                    state.palette.selected = state.palette.selected + 1
                    prise.request_frame()
                end
                return
            end

            local old_text = state.palette.input:text()
            if handle_text_input_key(state.palette.input, event.data) then
                if state.palette.input:text() ~= old_text then
                    state.palette.selected = 1
                end
                return
            end
            return
        end

        -- Handle session picker
        if state.session_picker.visible then
            -- Handle session rename mode
            if state.session_picker.renaming then
                local k = event.data.key

                if k == "Escape" then
                    close_session_rename()
                    return
                elseif k == "Enter" then
                    execute_session_rename()
                    return
                end
                handle_text_input_key(state.session_picker.input, event.data)
                return
            end

            local k = event.data.key
            local filtered = filter_sessions(state.session_picker.input:text())

            if k == "Escape" then
                close_session_picker()
                return
            elseif k == "Enter" then
                execute_session_switch()
                return
            elseif k == "ArrowUp" or (k == "p" and event.data.ctrl) then
                if state.session_picker.selected > 1 then
                    state.session_picker.selected = state.session_picker.selected - 1
                    -- Adjust scroll if needed
                    if state.session_picker.selected <= state.session_picker.scroll_offset then
                        state.session_picker.scroll_offset = state.session_picker.selected - 1
                    end
                end
                prise.request_frame()
                return
            elseif k == "ArrowDown" or (k == "n" and event.data.ctrl) then
                if state.session_picker.selected < #filtered then
                    state.session_picker.selected = state.session_picker.selected + 1
                    -- Adjust scroll if needed (items_start_y = 8, plus 1 for bottom padding)
                    local visible_height = math.max(1, state.screen_rows - 9)
                    if state.session_picker.selected > state.session_picker.scroll_offset + visible_height then
                        state.session_picker.scroll_offset = state.session_picker.selected - visible_height
                    end
                end
                prise.request_frame()
                return
            elseif k == "D" and event.data.shift then
                -- Delete the selected session (Shift+D)
                if #filtered > 0 then
                    local idx = state.session_picker.selected
                    if idx >= 1 and idx <= #filtered then
                        local target = filtered[idx]
                        local current_session = prise.get_session_name()
                        if target == current_session then
                            -- Can't delete the current session
                            prise.log.warn("Cannot delete the current session")
                            return
                        end
                        prise.delete_session(target)
                        -- Refresh the session list
                        state.session_picker.sessions = prise.list_sessions() or {}
                        state.session_picker.selected = math.min(
                            state.session_picker.selected,
                            math.max(1, #filter_sessions(state.session_picker.input:text()))
                        )
                        prise.request_frame()
                    end
                end
                return
            elseif k == "R" and event.data.shift then
                -- Rename the selected session (Shift+R)
                open_session_rename()
                return
            else
                -- Route remaining editing keys (char insert, backspace,
                -- cursor movement, word motions, kill_line, etc.) through
                -- the shared handler so the picker's search field behaves
                -- like other dialog text inputs. List navigation and
                -- action keys are already handled above.
                local old_text = state.session_picker.input:text()
                if handle_text_input_key(state.session_picker.input, event.data) then
                    local new_text = state.session_picker.input:text()
                    if new_text ~= old_text then
                        local new_filtered = filter_sessions(new_text)
                        state.session_picker.selected =
                            math.min(state.session_picker.selected, math.max(1, #new_filtered))
                        state.session_picker.scroll_offset = 0
                    end
                end
                return
            end
        end

        -- Handle layout picker
        if state.layout_picker.visible then
            local k = event.data.key
            local names = get_layout_names()

            if k == "Escape" then
                close_layout_picker()
                return
            elseif k == "Enter" then
                execute_selected_layout()
                return
            elseif k == "ArrowUp" or (k == "p" and event.data.ctrl) then
                if state.layout_picker.selected > 1 then
                    state.layout_picker.selected = state.layout_picker.selected - 1
                    if state.layout_picker.selected <= state.layout_picker.scroll_offset then
                        state.layout_picker.scroll_offset = state.layout_picker.selected - 1
                    end
                end
                prise.request_frame()
                return
            elseif k == "ArrowDown" or (k == "n" and event.data.ctrl) then
                if state.layout_picker.selected < #names then
                    state.layout_picker.selected = state.layout_picker.selected + 1
                    -- items_start_y = 8, plus 1 for bottom padding
                    local visible_height = math.max(1, state.screen_rows - 9)
                    if state.layout_picker.selected > state.layout_picker.scroll_offset + visible_height then
                        state.layout_picker.scroll_offset = state.layout_picker.selected - visible_height
                    end
                end
                prise.request_frame()
                return
            end
            return
        end

        -- Handle rename session prompt
        if state.rename.visible then
            local k = event.data.key

            if k == "Escape" then
                close_rename()
                return
            elseif k == "Enter" then
                execute_rename()
                return
            end
            handle_text_input_key(state.rename.input, event.data)
            return
        end

        -- Handle rename tab prompt
        if state.rename_tab.visible then
            local k = event.data.key

            if k == "Escape" then
                close_rename_tab()
                return
            elseif k == "Enter" then
                execute_rename_tab()
                return
            end
            handle_text_input_key(state.rename_tab.input, event.data)
            return
        end

        -- Handle swap tab with index prompt
        if state.swap_with_index and state.swap_with_index.visible then
            local k = event.data.key

            if k == "Escape" then
                state.swap_with_index.visible = false
                state.swap_with_index = nil
                prise.request_frame()
                return
            elseif k == "Enter" then
                local text = state.swap_with_index.input:text()
                local target_idx_num = tonumber(text)
                if target_idx_num then
                    local target_idx = math.floor(target_idx_num)
                    if target_idx >= 1 and target_idx <= #state.tabs and target_idx ~= state.active_tab then
                        swap_tabs(state.active_tab, target_idx)
                    end
                end
                state.swap_with_index.visible = false
                state.swap_with_index = nil
                prise.request_frame()
                return
            end
            handle_text_input_key(state.swap_with_index.input, event.data)
            prise.request_frame()
            return
        end

        -- Handle floating pane resize mode
        if state.floating.resize_mode then
            local k = event.data.key
            if k == "+" or (k == "=" and event.data.shift) then
                action_handlers.floating_increase_size()
                return
            elseif k == "-" then
                action_handlers.floating_decrease_size()
                return
            else
                -- Exit resize mode on any other key
                state.floating.resize_mode = false
                prise.request_frame()
                -- Don't return - let the key be processed normally
            end
        end

        -- Handle keybinds via matcher
        init_keybinds()

        -- Ignore modifier-only key presses (Shift, Ctrl, Alt, Super)
        if is_modifier_key(event.data.key) then
            return
        end

        local result = state.keybind_matcher:handle_key(event.data)

        if result.action or result.func then
            -- Cancel any pending timeout
            if state.timer then
                state.timer:cancel()
                state.timer = nil
            end
            state.pending_command = false

            -- Dispatch action
            if result.func then
                result.func()
            elseif result.action then
                local handler = action_handlers[result.action]
                if handler then
                    handler()
                end
            end
            prise.request_frame()
            return
        elseif result.pending then
            -- Key sequence in progress
            state.pending_command = true
            prise.request_frame()

            -- Cancel existing timeout and start new one
            if state.timer then
                state.timer:cancel()
            end
            state.timer = prise.set_timeout(1000, function()
                if state.pending_command then
                    state.pending_command = false
                    state.timer = nil
                    state.keybind_matcher:reset()
                    prise.request_frame()
                end
            end)
            return
        end

        -- No match - reset pending state if we were in one
        if state.pending_command then
            if state.timer then
                state.timer:cancel()
                state.timer = nil
            end
            state.pending_command = false
            prise.request_frame()
            -- Send the unmapped key to the focused PTY
            local root = get_active_root()
            if root and state.focused_id then
                local path = find_node_path(root, state.focused_id)
                if path then
                    local pane = path[#path]
                    pane.pty:send_key(event.data)
                end
            end
            return
        end

        -- Copy selection: Cmd+c (macOS) or Ctrl+Shift+c (Linux)
        if event.data.key == "c" then
            local is_copy = false
            if prise.platform == "macos" then
                is_copy = (event.data.super == true) and not event.data.ctrl and not event.data.alt
            else
                is_copy = (event.data.ctrl == true) and (event.data.shift == true) and not event.data.super
            end
            if is_copy then
                local pty = get_visible_floating_pty() or get_focused_pty()
                if pty then
                    pty:copy_selection()
                end
                return
            end
        end

        -- Route to floating pane if visible, otherwise to focused pane
        local tab = get_active_tab()
        if tab and tab.floating and tab.floating.visible then
            -- Send to floating pane
            if tab.floating.pane and tab.floating.pane.pty then
                tab.floating.pane.pty:send_key(event.data)
            end
            return
        else
            -- Pass key to focused PTY in main layout
            local root = get_active_root()
            if root and state.focused_id then
                local path = find_node_path(root, state.focused_id)
                if path then
                    local pane = path[#path]
                    pane.pty:send_key(event.data)
                end
            end
        end
    elseif event.type == "key_release" then
        local pty = get_visible_floating_pty() or get_focused_pty()
        if pty then
            local data = event.data
            data.release = true
            pty:send_key(data)
        end
    elseif event.type == "paste" then
        local text_sanitized = event.data.text:gsub("[\r\n\t]", " ")
        if state.palette.visible then
            state.palette.input:insert(text_sanitized)
            state.palette.selected = 1
            prise.request_frame()
        elseif state.rename_tab.visible then
            state.rename_tab.input:insert(text_sanitized)
            prise.request_frame()
        elseif state.rename.visible then
            state.rename.input:insert(text_sanitized)
            prise.request_frame()
        elseif state.session_picker.visible then
            state.session_picker.input:insert(text_sanitized)
            prise.request_frame()
        elseif state.swap_with_index and state.swap_with_index.visible then
            state.swap_with_index.input:insert(text_sanitized)
            prise.request_frame()
        else
            local pty = get_visible_floating_pty() or get_focused_pty()
            if pty then
                pty:send_paste(event.data.text)
            end
        end
    elseif event.type == "pty_exited" then
        local id = event.data.id
        prise.log.info("Lua: pty_exited " .. id)

        -- Check if this is a floating pane (check active tab first, then others)
        local active_tab = get_active_tab()
        if active_tab and active_tab.floating and active_tab.floating.pane.id == id then
            active_tab.floating = nil
            prise.request_frame()
            return
        end
        for _, tab in ipairs(state.tabs) do
            if tab ~= active_tab and tab.floating and tab.floating.pane.id == id then
                tab.floating = nil
                prise.request_frame()
                return
            end
        end

        local was_last = remove_pane_by_id(id)
        if not was_last then
            prise.save()
        end
    elseif event.type == "break_pane" then
        -- Move a pane out of its current tab into a brand-new tab of its own.
        -- Dumb primitive: no "which pane should break?" policy lives here —
        -- callers decide. Focus follows the moved pane if (and only if) the
        -- source tab is the currently active tab AND the caller did not opt
        -- out via data.focus = false; otherwise the operation is silent with
        -- no focus steal.
        --
        -- Cross-session extension (fn-45): when event.data.source_session is
        -- provided and the pane is not found in state.tabs (viewer is on a
        -- different session), the destination is the SOURCE session itself —
        -- the new tab lands in the source session's saved JSON via the
        -- file-based pair (prise.remove_pty_from_session +
        -- prise.place_pty_in_session). The viewer's session.tabs is NOT
        -- mutated. Matrix-wins per fn-45.
        --
        -- Placement policy: the new tab is inserted immediately to the RIGHT
        -- of the focused tab (state.active_tab), not appended to the end.
        -- The anchor is normalized via max(1, min(#tabs, active_tab or 1))
        -- with an explicit empty-tabs → index 1 branch. Anchor is CAPTURED AT
        -- HANDLER ENTRY (before any mutations) and decremented by 1 if a
        -- subsequent table.remove fires at an index <= anchor, so that
        -- "right of originally-focused tab" semantics survive intra-handler
        -- tree mutations.
        --
        -- keep in sync with partner handler on feat/break-pane-to-session
        -- (merged tiling.lua has two break_pane handlers; both must share
        -- this placement policy).
        local pty_id = event.data and event.data.pty_id
        if type(pty_id) ~= "number" then
            return false
        end

        -- Opt-out focus-follow. Default true preserves historical behavior;
        -- callers pass focus = false to break a pane in the background even
        -- when the source tab is active (e.g. the user is focused on a
        -- different pane in the same tab and shouldn't be yanked to the new
        -- tab).
        local follow_focus = not (event.data and event.data.focus == false)

        local src_tab_idx, src_tab = find_tab_for_pane(pty_id)
        if not src_tab then
            -- fn-45 cross-session arm: when source_session is provided, both
            -- remove and place target the SOURCE session — the new tab lands
            -- in source's JSON, not in the viewer's state.tabs. Viewer's
            -- session is left untouched.
            local source_session = event.data and event.data.source_session
            prise.log.info(
                "break_pane: cross-session entry pty="
                    .. tostring(pty_id)
                    .. " source="
                    .. tostring(source_session)
                    .. " viewer="
                    .. tostring(prise.get_session_name())
            )
            if type(source_session) == "string" and source_session ~= "" then
                local cwd = event.data and event.data.cwd
                if type(cwd) ~= "string" or cwd == "" then
                    prise.log.warn(
                        "break_pane: cross-session missing cwd for pty="
                            .. tostring(pty_id)
                            .. " source="
                            .. source_session
                            .. " — cannot place into source session"
                    )
                    return false
                end
                local tab_title = event.data and event.data.tab_title
                prise.log.info(
                    "break_pane: cross-session pre-remove pty=" .. tostring(pty_id) .. " source=" .. source_session
                )
                local removed = prise.remove_pty_from_session(source_session, pty_id)
                if not removed then
                    prise.log.warn(
                        "break_pane: cross-session remove failed for pty="
                            .. tostring(pty_id)
                            .. " source="
                            .. source_session
                    )
                    return false
                end
                prise.log.info(
                    "break_pane: cross-session post-remove pty="
                        .. tostring(pty_id)
                        .. " source="
                        .. source_session
                        .. " — placing into source"
                )
                local placed = prise.place_pty_in_session(source_session, pty_id, cwd, tab_title)
                if not placed then
                    prise.log.warn(
                        "break_pane: cross-session place failed for pty="
                            .. tostring(pty_id)
                            .. " source="
                            .. source_session
                            .. " (orphaned after remove)"
                    )
                    return false
                end
                prise.log.info(
                    "break_pane: cross-session done pty=" .. tostring(pty_id) .. " source=" .. source_session
                )
                return true
            end
            return false
        end

        -- Require the pane to live in the tileable tree (not a floating or
        -- overlay slot). find_tab_for_pane only walks tab.root, so a non-nil
        -- src_tab already implies this — find_node_path here is belt-and-
        -- suspenders and doubles as a handle on the leaf node reference.
        local src_path = find_node_path(src_tab.root, pty_id)
        if not src_path then
            return
        end
        local src_leaf = src_path[#src_path]

        -- Defensive solo-pane no-op. Can't happen under the arthack policy
        -- (it only breaks when cohabitants exist) but keeps this primitive
        -- safe for direct callers: breaking the only pane in a tab would
        -- leave the source empty and just shuffle tab ordering for nothing.
        if is_pane(src_tab.root) and src_tab.root.id == pty_id then
            return
        end

        local was_active = (src_tab_idx == state.active_tab)

        -- Capture the placement anchor BEFORE any mutation. Normalize
        -- state.active_tab through max(1, min(#tabs, active_tab or 1)) so
        -- nil / 0 / overflow all route to a valid index. This must happen
        -- before table.remove below so the decrement-on-left-removal rule
        -- has something deterministic to fix up (see anchor_adjust below).
        local anchor = math.max(1, math.min(#state.tabs, state.active_tab or 1))

        -- Clear any zoom state referencing the moved pane so it doesn't
        -- follow into the new tab with stale bookkeeping.
        if state.zoomed_pane_id == pty_id then
            state.zoomed_pane_id = nil
        end
        for _, t in ipairs(state.tabs) do
            if t.zoomed_pane_id == pty_id then
                t.zoomed_pane_id = nil
            end
        end

        -- Detach the leaf from the source tree. remove_pane_recursive
        -- collapses any single-child split on the way up, so the survivor
        -- is automatically promoted.
        local new_root, next_focus = remove_pane_recursive(src_tab.root, pty_id)
        src_tab.root = new_root

        -- Defensive: if the tree collapsed to nothing (should not happen —
        -- the solo-pane guard returns above), close auxiliary panes and
        -- remove the emptied tab rather than leaving it headless. Under
        -- the placement policy this branch is unreachable with the solo-
        -- pane guard active; preserving historical behavior (drop the
        -- broken pane). If future guard changes make this branch live,
        -- the captured anchor must be decremented here to keep placement
        -- consistent: src_tab_idx <= anchor by construction in this
        -- branch (the removed tab was the pane's host and was <= active).
        if not new_root and src_tab_idx then
            close_auxiliary_panes(src_tab)
            table.remove(state.tabs, src_tab_idx)
            -- Decrement-on-left-removal: apply the same rule as the main
            -- path so the anchor keeps pointing at the same logical tab
            -- after the source collapse. Noted for future callers that
            -- reach this branch; the early return below means placement
            -- doesn't fire here today.
            if src_tab_idx <= anchor then
                anchor = math.max(0, anchor - 1)
            end
            if was_active then
                -- Keep state.active_tab valid even when follow_focus is
                -- false — the active tab was just removed, so the index
                -- must be retargeted regardless.
                local new_idx = math.min(src_tab_idx, #state.tabs)
                state.active_tab = new_idx
                local new_tab = state.tabs[new_idx]
                if new_tab then
                    state.zoomed_pane_id = new_tab.zoomed_pane_id
                    new_tab.zoomed_pane_id = nil
                end
                if follow_focus then
                    local new_focus_id = new_tab and new_tab.last_focused_id
                    if new_tab and new_focus_id and not find_node_path(new_tab.root, new_focus_id) then
                        local first = get_first_leaf(new_tab.root)
                        new_focus_id = first and first.id or nil
                    end
                    local old_focused = state.focused_id
                    state.focused_id = new_focus_id
                    update_pty_focus(old_focused, new_focus_id)
                    update_cached_git_branch()
                end
            elseif src_tab_idx < state.active_tab then
                state.active_tab = state.active_tab - 1
            end
            prise.save()
            prise.request_frame()
            return
        end

        -- Fix the source tab's saved focus if it pointed at the moved pane.
        if src_tab.last_focused_id == pty_id then
            if next_focus then
                src_tab.last_focused_id = next_focus
            else
                local first = get_first_leaf(src_tab.root)
                src_tab.last_focused_id = first and first.id or nil
            end
        end

        -- Allocate a fresh tab whose root IS the moved leaf.
        local tab_id = state.next_tab_id
        state.next_tab_id = tab_id + 1
        ---@type Tab
        local new_tab = {
            id = tab_id,
            root = src_leaf,
            last_focused_id = src_leaf.id,
        }
        -- Placement: insert at anchor + 1 (right of the focused tab). When
        -- state.tabs is empty (no-op in practice under current guards, but
        -- encoded for safety), the new tab becomes the only tab at index 1.
        local insert_idx = (#state.tabs == 0) and 1 or (anchor + 1)
        table.insert(state.tabs, insert_idx, new_tab)

        if was_active and follow_focus then
            -- Use the captured (pre-mutation) anchor, not #state.tabs. The
            -- new tab lives at insert_idx; set_active_tab_index handles
            -- zoom save/restore on the old tab, picks the new tab's
            -- last_focused_id, and fires update_pty_focus.
            set_active_tab_index(insert_idx)
        end
        -- When the source tab was inactive OR the caller opted out of focus-
        -- follow: state.active_tab is preserved. Insert at anchor + 1 always
        -- lands to the RIGHT of the active tab (insert_idx = active_tab + 1
        -- after normalization), so inserting doesn't shift the active tab's
        -- index — it stays at the same position in state.tabs and still
        -- resolves to the same logical tab. state.focused_id still refers
        -- to a pane in the still-active tab — in the inactive case, not the
        -- moved pane by invariant; in the opt-out case, the focused pane is
        -- a sibling of the moved pane in the (still-active) source tab. No
        -- focus mutation needed either way.

        prise.save()
        prise.request_frame()
    elseif event.type == "move_pane_to_session" then
        -- Move a pane out of its current tab AND out of the current session
        -- entirely, landing it in another session's saved state. Callers
        -- own the policy of which session to land in (cwd basename, per-
        -- project routing, etc.); this primitive just executes the move.
        --
        -- Returns a tagged table `{ ok = <bool>, reason = <string>, ... }`.
        -- `reason` is one of:
        --   moved                              — success
        --   bad_args                           — missing/ill-typed pty_id,
        --                                         session_name, or cwd
        --   absent_from_viewer                 — pane not in state.tabs
        --                                         and no source_session
        --                                         was provided for the
        --                                         cross-session JSON-only
        --                                         path
        --   cross_session_remove_failed        — viewer-off-source JSON
        --                                         remove failed before
        --                                         any place; no state
        --                                         was mutated
        --   cross_session_place_failed         — viewer-off-source JSON
        --                                         place failed after a
        --                                         successful remove; the
        --                                         pty is orphaned (no
        --                                         source tab, no dest)
        --   source_solo_destination_unreachable— single-pane source that
        --                                         couldn't land on the
        --                                         destination; source
        --                                         session stays intact
        -- Non-nil tables are truthy in Lua, so existing `if ret then ...`
        -- checks still work; callers that need reason-aware branching
        -- read `ret.ok` / `ret.reason`.
        --
        -- Callers can gate downstream effects (DB re-key, event emission)
        -- on `ret.ok` so a no-op doesn't produce a ghost move. The pane
        -- isn't in the viewer's state when the pane lives in another
        -- session's saved JSON (find_tab_for_pane only walks state.tabs)
        -- — the caller either needs to be attached to the source session
        -- or route the move through a cross-session primitive.
        --
        -- Post-move source cleanup: after the move succeeds, the source
        -- tab is dropped from state.tabs. When that drop leaves
        -- `#state.tabs == 0` the source session is empty — this primitive
        -- closes it via `prise.close_session` so the caller doesn't see a
        -- ghost viewer on a session with no tabs. Ordering is
        -- source-save-then-place-dest-then-close so fn-8's viewer-on-
        -- destination race guarantees stay intact.
        --
        -- Invariant caveat: the tree mutation happens BEFORE the cross-
        -- session file write. If prise.place_pty_in_session fails, we log
        -- and still return `{ ok = true, reason = "moved" }` — saving
        -- the mutated source state is more important than trying to
        -- unwind half a cross-session move, and the pane has left the
        -- source tree from the caller's perspective.
        local pty_id = event.data and event.data.pty_id
        local session_name = event.data and event.data.session_name
        local cwd = event.data and event.data.cwd
        local tab_title = event.data and event.data.tab_title
        if type(pty_id) ~= "number" then
            return { ok = false, reason = "bad_args" }
        end
        if type(session_name) ~= "string" or session_name == "" then
            return { ok = false, reason = "bad_args" }
        end
        if type(cwd) ~= "string" or cwd == "" then
            return { ok = false, reason = "bad_args" }
        end

        local src_tab_idx, src_tab = find_tab_for_pane(pty_id)
        if not src_tab or not src_tab_idx then
            -- Cross-session move: the pane lives in another session's
            -- saved JSON that our viewer never loads. When the caller
            -- hands us the source session name explicitly, handle
            -- remove + place. Remove is always file-based (viewer is
            -- not on source by this branch's precondition). For the
            -- place half, split by viewer location: if the viewer is
            -- already on the destination session, mutate state.tabs
            -- in-memory to sidestep the autosave race; otherwise use
            -- the file-based path.
            local source_session = event.data.source_session
            if type(source_session) == "string" and source_session ~= "" then
                local removed = prise.remove_pty_from_session(source_session, pty_id)
                if not removed then
                    prise.log.warn(
                        "move_pane_to_session: cross-session remove failed for pty="
                            .. tostring(pty_id)
                            .. " source="
                            .. source_session
                    )
                    return { ok = false, reason = "cross_session_remove_failed" }
                end
                local current = prise.get_session_name()
                if current == session_name then
                    -- Viewer is on the destination session: append as a
                    -- new in-memory tab so the pending autosave serializes
                    -- authoritative state (no file-write race).
                    local tab_id = state.next_tab_id
                    state.next_tab_id = tab_id + 1
                    ---@type Tab
                    local new_tab = {
                        id = tab_id,
                        root = { type = "pane", pty_id = pty_id, cwd = cwd },
                        title = tab_title,
                        last_focused_id = pty_id,
                    }
                    table.insert(state.tabs, new_tab)
                    prise.save()
                    prise.request_frame()
                    return { ok = true, reason = "moved" }
                else
                    -- Viewer is on an unrelated session: file-based place.
                    local placed = prise.place_pty_in_session(session_name, pty_id, cwd, tab_title)
                    if not placed then
                        prise.log.warn(
                            "move_pane_to_session: cross-session place failed for pty="
                                .. tostring(pty_id)
                                .. " session="
                                .. session_name
                                .. " (orphaned after remove)"
                        )
                        return { ok = false, reason = "cross_session_place_failed" }
                    end
                    -- No prise.request_frame() here, intentionally. The
                    -- viewer is on neither the source nor the destination
                    -- session; both `state.tabs` and any rendered widgets
                    -- are untouched by this branch (the place is a pure
                    -- file write into another session's JSON). The
                    -- in-memory arm above DOES request a frame because it
                    -- mutates `state.tabs` directly. Re-adding a frame
                    -- request here would be a wasted render with no
                    -- changed bytes to draw.
                    return { ok = true, reason = "moved" }
                end
            end
            return { ok = false, reason = "absent_from_viewer" }
        end
        -- find_tab_for_pane also resolves floating/overlay panes; require
        -- the leaf to live in the tileable tree. Doubles as a nil-guard
        -- on the tree walk.
        if not find_node_path(src_tab.root, pty_id) then
            return { ok = false, reason = "absent_from_viewer" }
        end

        -- Solo-pane-in-only-tab used to refuse the move outright; the
        -- primitive now lets the move through and cleans up the empty
        -- source session at the tail of this handler. Matches the
        -- tmux/wezterm/zellij pattern: post-move cleanup, not pre-move
        -- refusal. Track the case so we can emit a structured reason if
        -- the destination place fails and we have to restore intent.
        local source_was_solo_only = (is_pane(src_tab.root) and src_tab.root.id == pty_id and #state.tabs == 1)
        local source_session_for_close = source_was_solo_only and prise.get_session_name() or nil

        local was_active = (src_tab_idx == state.active_tab)
        local was_focused = (state.focused_id == pty_id)

        -- Clear any zoom bookkeeping so the next save doesn't emit a
        -- dangling reference to the moved pane.
        if state.zoomed_pane_id == pty_id then
            state.zoomed_pane_id = nil
        end
        for _, t in ipairs(state.tabs) do
            if t.zoomed_pane_id == pty_id then
                t.zoomed_pane_id = nil
            end
        end

        -- Detach the leaf. remove_pane_recursive collapses single-child
        -- splits on the way up; if the source tab was a solo pane in a
        -- multi-tab session, new_root is nil and we drop the whole tab.
        local new_root, next_focus = remove_pane_recursive(src_tab.root, pty_id)

        if new_root == nil then
            -- Close floating/overlay panes that would be orphaned by
            -- dropping this tab.
            close_auxiliary_panes(src_tab)
            -- Source tab emptied — drop it and pick a new active tab if
            -- we were on it.
            table.remove(state.tabs, src_tab_idx)
            if was_active then
                -- Prefer the tab that shifted into the old slot; fall
                -- back to the new tail when the removed tab was last.
                local new_idx = math.min(src_tab_idx, #state.tabs)
                state.active_tab = new_idx
                local new_tab = state.tabs[new_idx]
                -- Restore zoom state from the destination tab (mirrors
                -- remove_pane_by_id's handoff at the same point).
                if new_tab then
                    state.zoomed_pane_id = new_tab.zoomed_pane_id
                    new_tab.zoomed_pane_id = nil
                end
                local new_focus = new_tab and new_tab.last_focused_id
                if new_tab and new_focus and not find_node_path(new_tab.root, new_focus) then
                    local first = get_first_leaf(new_tab.root)
                    new_focus = first and first.id or nil
                end
                if new_tab and not new_focus then
                    local first = get_first_leaf(new_tab.root)
                    new_focus = first and first.id or nil
                end
                local old_focused = state.focused_id
                state.focused_id = new_focus
                update_pty_focus(old_focused, new_focus)
                update_cached_git_branch()
            elseif src_tab_idx < state.active_tab then
                -- Removing a tab before the active one shifts every
                -- index after it down by one.
                state.active_tab = state.active_tab - 1
            end
        else
            src_tab.root = new_root
            if src_tab.last_focused_id == pty_id then
                if next_focus then
                    src_tab.last_focused_id = next_focus
                else
                    local first = get_first_leaf(src_tab.root)
                    src_tab.last_focused_id = first and first.id or nil
                end
            end
            if was_active and was_focused then
                -- Source tab stayed active but its focused pane left.
                -- Retarget state.focused_id in-place; we're not changing
                -- tabs so set_active_tab_index would early-return.
                local new_focus = src_tab.last_focused_id
                if new_focus and not find_node_path(src_tab.root, new_focus) then
                    local first = get_first_leaf(src_tab.root)
                    new_focus = first and first.id or nil
                end
                local old_focused = state.focused_id
                state.focused_id = new_focus
                update_pty_focus(old_focused, new_focus)
                update_cached_git_branch()
            end
        end

        -- Write the detached leaf into the target session's saved state.
        -- Point of no return: any failure here leaves the PTY orphaned
        -- in-memory (still alive, no tree reference). We log and move on
        -- — saving the mutated source state is more important than
        -- trying to unwind half a cross-session move.
        local placed = prise.place_pty_in_session(session_name, pty_id, cwd, tab_title)
        if not placed then
            prise.log.warn(
                "move_pane_to_session: place failed for pty=" .. tostring(pty_id) .. " session=" .. session_name
            )
        end

        -- Flush source state BEFORE any cross-session close. fn-8 race
        -- guarantee: destination write happened above, source save
        -- captures the now-empty tree so the viewer and on-disk state
        -- agree.
        prise.save()

        -- Close the now-empty source session when the move drained its
        -- last tab. `source_session_for_close` is set above only when
        -- the source was the single tab holding a single pane; by here
        -- that tab has been removed from state.tabs and the session is
        -- genuinely empty from the viewer's vantage point.
        --
        -- Zero-sessions transient: when closing the only session in
        -- prise, the viewer is momentarily attached to nothing. Prise
        -- tolerates this as long as the next operation creates a
        -- session (the destination place above is exactly that — but
        -- it's a file-based write, not a viewer attach). The human
        -- workflow that ends up here (cross-session move with focus
        -- follow) issues `prise.switch_session(destination)` from the
        -- caller moments after this primitive returns, landing the
        -- viewer on the new session before any input would crash.
        if source_session_for_close and source_session_for_close ~= session_name then
            local closed = prise.close_session(source_session_for_close)
            if not closed then
                prise.log.warn(
                    "move_pane_to_session: close_session failed for session=" .. tostring(source_session_for_close)
                )
            end
        end

        prise.request_frame()

        if not placed and source_was_solo_only then
            -- The source session was already drained (tabs dropped, save
            -- flushed, close_session may have fired). The destination
            -- refused the leaf, so the PTY is orphaned and the
            -- workflow's post-move steps (viewer switch, DB re-key)
            -- would land on a non-existent tab. Surface a distinct
            -- reason so the caller can skip those effects without
            -- colliding with the cross-session `absent_from_viewer`
            -- path.
            return { ok = false, reason = "source_solo_destination_unreachable" }
        end
        return { ok = true, reason = "moved" }
    elseif event.type == "pty_spawned" then
        local data = event.data
        prise.log.info("Lua: pty_spawned " .. data.id)

        -- Cross-session placement: write PTY into target session file, don't attach
        if data.session then
            local current = prise.get_session_name()
            if current ~= data.session then
                local ok = prise.place_pty_in_session(data.session, data.id, data.cwd, data.title)
                if ok then
                    prise.log.info("Placed PTY " .. data.id .. " in session " .. data.session)
                end
                prise.request_frame()
                return
            end
        end

        -- Same-session placement (or no session field)
        if data.tab or data.title or data.focus ~= nil or data.session then
            local new_tab = true
            if data.tab and data.tab ~= "new" then
                local idx = find_tab_by_title(data.tab)
                if idx then
                    set_active_tab_index(idx)
                    new_tab = false
                end
            end

            state.pending_spawns[data.id] = {
                new_tab = new_tab,
                no_focus = data.focus ~= true,
            }

            prise.attach(data.id)

            if data.title then
                state.pending_title_renames[data.id] = data.title
            end
        end
    elseif event.type == "mouse" then
        local d = event.data

        -- Track tab and close button hover state on motion
        if d.action == "motion" and #state.tab_regions > 0 then
            local new_hover = nil
            local new_close_hover = nil
            if d.y < 1 then
                -- Check close button regions first (they're more specific)
                for _, region in ipairs(state.tab_close_regions) do
                    if d.x >= region.start_x and d.x < region.end_x then
                        new_close_hover = region.tab_index
                        new_hover = region.tab_index
                        break
                    end
                end
                -- If not on close button, check tab regions
                if not new_close_hover then
                    for _, region in ipairs(state.tab_regions) do
                        if d.x >= region.start_x and d.x < region.end_x then
                            new_hover = region.tab_index
                            break
                        end
                    end
                end
            end
            if new_hover ~= state.hovered_tab or new_close_hover ~= state.hovered_close_tab then
                state.hovered_tab = new_hover
                state.hovered_close_tab = new_close_hover
                prise.request_frame()
            end
        end

        if d.action == "press" and d.button == "left" then
            -- Check if click is on session picker item
            if
                state.session_picker.visible
                and not state.session_picker.renaming
                and #state.session_picker.regions > 0
            then
                local click_x = math.floor(d.x)
                local click_y = math.floor(d.y)
                local modal_start_x, modal_end_x = modal_x_bounds()

                if click_x >= modal_start_x and click_x < modal_end_x then
                    for _, region in ipairs(state.session_picker.regions) do
                        if click_y >= region.start_y and click_y < region.end_y then
                            if state.session_picker.selected == region.index then
                                execute_session_switch()
                            else
                                state.session_picker.selected = region.index
                                prise.request_frame()
                            end
                            return
                        end
                    end
                end
            end

            -- Check if click is on layout picker item
            if state.layout_picker.visible and #state.layout_picker.regions > 0 then
                local click_x = math.floor(d.x)
                local click_y = math.floor(d.y)
                local modal_start_x, modal_end_x = modal_x_bounds()

                if click_x >= modal_start_x and click_x < modal_end_x then
                    for _, region in ipairs(state.layout_picker.regions) do
                        if click_y >= region.start_y and click_y < region.end_y then
                            if state.layout_picker.selected == region.index then
                                execute_selected_layout()
                            else
                                state.layout_picker.selected = region.index
                                prise.request_frame()
                            end
                            return
                        end
                    end
                end
            end

            -- Check if click is on command palette item
            if state.palette.visible and #state.palette.regions > 0 then
                -- Convert float coords to integer cell positions
                local click_x = math.floor(d.x)
                local click_y = math.floor(d.y)

                local palette_start_x, palette_end_x = modal_x_bounds()

                if click_x >= palette_start_x and click_x < palette_end_x then
                    for _, region in ipairs(state.palette.regions) do
                        if click_y >= region.start_y and click_y < region.end_y then
                            if state.palette.selected == region.index then
                                -- Already selected, execute it
                                execute_selected()
                            else
                                -- First click, just highlight it
                                state.palette.selected = region.index
                                prise.request_frame()
                            end
                            return
                        end
                    end
                end
            end

            -- Check if click is on tab bar (y < 1 and we have tab regions)
            if d.y < 1 and #state.tab_regions > 0 then
                -- Check close button regions first
                for _, region in ipairs(state.tab_close_regions) do
                    if d.x >= region.start_x and d.x < region.end_x then
                        close_tab(region.tab_index)
                        return
                    end
                end
                -- Then check tab regions for switching
                for _, region in ipairs(state.tab_regions) do
                    if d.x >= region.start_x and d.x < region.end_x then
                        set_active_tab_index(region.tab_index)
                        return
                    end
                end
            end

            -- Focus the clicked pane
            if d.target and d.target ~= state.focused_id then
                local old_id = state.focused_id
                state.focused_id = d.target
                update_pty_focus(old_id, state.focused_id)
                prise.request_frame()
            end

            -- Hide floating pane when clicking on main pane
            local tab = get_active_tab()
            if
                tab
                and tab.floating
                and tab.floating.visible
                and tab.floating.pane
                and d.target ~= tab.floating.pane.id
            then
                tab.floating.visible = false
                prise.request_frame()
            end
        end
        -- Forward mouse events to floating pane if visible and targeted
        local floating_tab = get_active_tab()
        if
            floating_tab
            and floating_tab.floating
            and floating_tab.floating.visible
            and floating_tab.floating.pane
            and d.target == floating_tab.floating.pane.id
        then
            if floating_tab.floating.pane.pty then
                floating_tab.floating.pane.pty:send_mouse({
                    x = d.target_x or 0,
                    y = d.target_y or 0,
                    button = d.button,
                    event_type = d.action,
                    mods = d.mods,
                })
            end
            return
        end

        -- Forward mouse events to the target PTY if there is one
        local root = get_active_root()
        if d.target and root then
            local path = find_node_path(root, d.target)
            if path then
                local pane = path[#path]
                pane.pty:send_mouse({
                    x = d.target_x or 0,
                    y = d.target_y or 0,
                    button = d.button,
                    event_type = d.action,
                    mods = d.mods,
                })
            end
        end
    elseif event.type == "winsize" then
        state.screen_cols = event.data.cols or state.screen_cols
        state.screen_rows = event.data.rows or state.screen_rows
        prise.request_frame()
    elseif event.type == "focus_in" then
        state.app_focused = true
        local pty = get_visible_floating_pty() or get_focused_pty()
        if pty then
            pty:set_focus(true)
        end
    elseif event.type == "focus_out" then
        state.app_focused = false
        local pty = get_visible_floating_pty() or get_focused_pty()
        if pty then
            pty:set_focus(false)
        end
    elseif event.type == "split_resize" then
        -- Handle mouse drag resize
        local d = event.data
        local split_id = d.parent_id
        local child_index = d.child_index
        local new_ratio = d.ratio

        -- In separator mode, widget children include separators interleaved with panes.
        -- Widget structure: [Pane0, Sep, Pane1, Sep, Pane2, ...]
        -- Lua state structure: [Pane0, Pane1, Pane2, ...]
        -- Map widget child_index to lua pane_index:
        -- - Even widget indices (0, 2, 4, ...) are panes
        -- - Odd widget indices (1, 3, 5, ...) are separators
        -- For a handle at the boundary after widget child N:
        -- - If N is even (a pane), pane_index = N / 2
        -- - If N is odd (a separator), pane_index = (N - 1) / 2 (the pane before the separator)
        local pane_index = child_index
        if config.borders.mode == "separator" and should_show_borders() then
            if child_index % 2 == 0 then
                pane_index = child_index // 2
            else
                pane_index = (child_index - 1) // 2
            end
        end

        -- Find the split by id and update the child's ratio
        local function update_split_ratio(node)
            if not node then
                return false
            end
            if is_split(node) then
                if node.split_id == split_id then
                    -- Found it - update the pane's ratio
                    if node.children[pane_index + 1] then
                        node.children[pane_index + 1].ratio = new_ratio
                    end
                    return true
                end
                for _, child in ipairs(node.children) do
                    if update_split_ratio(child) then
                        return true
                    end
                end
            end
            return false
        end

        local root = get_active_root()
        if update_split_ratio(root) then
            prise.request_frame()
            prise.save() -- Auto-save on layout change
        end
    elseif event.type == "rename_tab" then
        local pty_id = event.data.pty_id
        local title = event.data.title
        local _, tab = find_tab_for_pane(pty_id)
        if tab then
            if title == "" then
                tab.title = nil
            else
                tab.title = title
            end
            prise.save()
            prise.request_frame()
        end
    elseif event.type == "break_pane" then
        -- Move a pane out of its current tab into a brand-new tab of its own.
        -- Dumb primitive: no "which pane should break?" policy lives here —
        -- callers decide. Focus follows the moved pane if (and only if) the
        -- source tab is the currently active tab AND the caller did not opt
        -- out via data.focus = false; otherwise the operation is silent with
        -- no focus steal.
        --
        -- Cross-session extension: when event.data.source_session is provided
        -- and the pane is not found in state.tabs (viewer is on a different
        -- session), the destination is the SOURCE session itself — the new
        -- tab lands in the source session's saved JSON via the file-based
        -- pair (prise.remove_pty_from_session + prise.place_pty_in_session).
        -- The viewer's session.tabs is NOT mutated. Matrix-wins per fn-45.
        --
        -- Returns true on success, false on partial failure (remove succeeded
        -- but place failed — pane orphaned). No rollback — log warn and return
        -- false, mirroring the move primitive's stance.
        --
        -- Placement policy (same-session branch below): the new tab is
        -- inserted immediately to the RIGHT of the focused tab
        -- (state.active_tab), not appended to the end. Anchor is normalized
        -- via max(1, min(#tabs, active_tab or 1)) with an explicit empty-tabs
        -- → index 1 branch.
        --
        -- For the cross-session arm: placement is server-side via
        -- appendTabToSessionFile, which appends at the end of source's tabs[].
        -- For B5's setup (1 tab, active_tab=1) this matches the matrix's
        -- normalize(active_tab)+1 expectation.
        --
        -- keep in sync with partner handler on feat/break-pane (merged
        -- tiling.lua has two break_pane handlers; both must share this
        -- placement policy).
        local pty_id = event.data and event.data.pty_id
        if type(pty_id) ~= "number" then
            return false
        end

        -- Opt-out focus-follow. Default true preserves historical behavior;
        -- callers pass focus = false to break a pane in the background even
        -- when the source tab is active (e.g. the user is focused on a
        -- different pane in the same tab and shouldn't be yanked to the new
        -- tab).
        local follow_focus = not (event.data and event.data.focus == false)

        -- Capture the placement anchor BEFORE any mutation. Normalize
        -- state.active_tab through max(1, min(#tabs, active_tab or 1)) so
        -- nil / 0 / overflow all route to a valid index. Applied to the
        -- same-session branch below.
        local anchor = math.max(1, math.min(#state.tabs, state.active_tab or 1))
        -- Insertion index: empty-tabs degenerate case lands at 1, otherwise
        -- right of the anchor.
        local function placement_index()
            return (#state.tabs == 0) and 1 or (anchor + 1)
        end

        local src_tab_idx, src_tab = find_tab_for_pane(pty_id)
        if not src_tab then
            -- Cross-session break: the pane lives in another session's saved
            -- JSON. When source_session is provided, both remove and place
            -- target the SOURCE session — the new tab lands in source's JSON,
            -- NOT in the viewer's state.tabs. Viewer's session is left
            -- untouched (mtime not advanced, state.tabs not mutated,
            -- active_tab unchanged).
            local source_session = event.data and event.data.source_session
            prise.log.info(
                "break_pane: cross-session entry pty="
                    .. tostring(pty_id)
                    .. " source="
                    .. tostring(source_session)
                    .. " viewer="
                    .. tostring(prise.get_session_name())
            )
            if type(source_session) == "string" and source_session ~= "" then
                -- cwd is required by prise.place_pty_in_session and is plumbed
                -- through the manage_pane intent from arthack init.lua
                -- (params.cwd → break_pane data.cwd). When absent, we cannot
                -- perform the cross-session place — fail visibly.
                local cwd = event.data and event.data.cwd
                if type(cwd) ~= "string" or cwd == "" then
                    prise.log.warn(
                        "break_pane: cross-session missing cwd for pty="
                            .. tostring(pty_id)
                            .. " source="
                            .. source_session
                            .. " — cannot place into source session"
                    )
                    return false
                end
                local tab_title = event.data and event.data.tab_title
                prise.log.info(
                    "break_pane: cross-session pre-remove pty=" .. tostring(pty_id) .. " source=" .. source_session
                )
                local removed = prise.remove_pty_from_session(source_session, pty_id)
                if not removed then
                    prise.log.warn(
                        "break_pane: cross-session remove failed for pty="
                            .. tostring(pty_id)
                            .. " source="
                            .. source_session
                    )
                    return false
                end
                prise.log.info(
                    "break_pane: cross-session post-remove pty="
                        .. tostring(pty_id)
                        .. " source="
                        .. source_session
                        .. " — placing into source"
                )
                -- Place into the SOURCE session's JSON file (matrix-wins:
                -- C_new lands in alpha, not in the viewer's session). The
                -- file-based path appends at the end of source's tabs[]
                -- (server-side appendTabToSessionFile).
                local placed = prise.place_pty_in_session(source_session, pty_id, cwd, tab_title)
                if not placed then
                    prise.log.warn(
                        "break_pane: cross-session place failed for pty="
                            .. tostring(pty_id)
                            .. " source="
                            .. source_session
                            .. " (orphaned after remove)"
                    )
                    return false
                end
                prise.log.info(
                    "break_pane: cross-session done pty=" .. tostring(pty_id) .. " source=" .. source_session
                )
                -- Viewer's session is untouched — no save, no request_frame.
                return true
            end
            return false
        end

        -- Require the pane to live in the tileable tree (not a floating or
        -- overlay slot). find_tab_for_pane only walks tab.root, so a non-nil
        -- src_tab already implies this — find_node_path here is belt-and-
        -- suspenders and doubles as a handle on the leaf node reference.
        local src_path = find_node_path(src_tab.root, pty_id)
        if not src_path then
            return false
        end
        local src_leaf = src_path[#src_path]

        -- Defensive solo-pane no-op. Can't happen under the arthack policy
        -- (it only breaks when cohabitants exist) but keeps this primitive
        -- safe for direct callers: breaking the only pane in a tab would
        -- leave the source empty and just shuffle tab ordering for nothing.
        if is_pane(src_tab.root) and src_tab.root.id == pty_id then
            return false
        end

        -- Reject when removing the pane would empty the source session
        -- entirely (sole pane in only tab — mirrors move_pane_to_session's
        -- solo-in-only-tab refusal).
        if is_pane(src_tab.root) and src_tab.root.id == pty_id and #state.tabs == 1 then
            return false
        end

        local was_active = (src_tab_idx == state.active_tab)

        -- Clear any zoom state referencing the moved pane so it doesn't
        -- follow into the new tab with stale bookkeeping.
        if state.zoomed_pane_id == pty_id then
            state.zoomed_pane_id = nil
        end
        for _, t in ipairs(state.tabs) do
            if t.zoomed_pane_id == pty_id then
                t.zoomed_pane_id = nil
            end
        end

        -- Detach the leaf from the source tree. remove_pane_recursive
        -- collapses any single-child split on the way up, so the survivor
        -- is automatically promoted.
        local new_root, next_focus = remove_pane_recursive(src_tab.root, pty_id)
        src_tab.root = new_root

        -- Defensive: if the tree collapsed to nothing (should not happen —
        -- the solo-pane guard returns above), close auxiliary panes and
        -- remove the emptied tab rather than leaving it headless. Under
        -- the placement policy this branch is unreachable with the solo-
        -- pane guard active; preserving historical behavior (drop the
        -- broken pane). If future guard changes make this branch live,
        -- the captured anchor must be decremented here to keep placement
        -- consistent: src_tab_idx <= anchor by construction in this
        -- branch (the removed tab was the pane's host and was <= active).
        if not new_root and src_tab_idx then
            close_auxiliary_panes(src_tab)
            table.remove(state.tabs, src_tab_idx)
            -- Decrement-on-left-removal: apply the same rule as the main
            -- path so the anchor keeps pointing at the same logical tab
            -- after the source collapse. Noted for future callers that
            -- reach this branch; the early return below means placement
            -- doesn't fire here today.
            if src_tab_idx <= anchor then
                anchor = math.max(0, anchor - 1)
            end
            if was_active then
                -- Keep state.active_tab valid even when follow_focus is
                -- false — the active tab was just removed, so the index
                -- must be retargeted regardless.
                local new_idx = math.min(src_tab_idx, #state.tabs)
                state.active_tab = new_idx
                local new_tab = state.tabs[new_idx]
                if new_tab then
                    state.zoomed_pane_id = new_tab.zoomed_pane_id
                    new_tab.zoomed_pane_id = nil
                end
                if follow_focus then
                    local new_focus_id = new_tab and new_tab.last_focused_id
                    if new_tab and new_focus_id and not find_node_path(new_tab.root, new_focus_id) then
                        local first = get_first_leaf(new_tab.root)
                        new_focus_id = first and first.id or nil
                    end
                    local old_focused = state.focused_id
                    state.focused_id = new_focus_id
                    update_pty_focus(old_focused, new_focus_id)
                    update_cached_git_branch()
                end
            elseif src_tab_idx < state.active_tab then
                state.active_tab = state.active_tab - 1
            end
            prise.save()
            prise.request_frame()
            return true
        end

        -- Fix the source tab's saved focus if it pointed at the moved pane.
        if src_tab.last_focused_id == pty_id then
            if next_focus then
                src_tab.last_focused_id = next_focus
            else
                local first = get_first_leaf(src_tab.root)
                src_tab.last_focused_id = first and first.id or nil
            end
        end

        -- Allocate a fresh tab whose root IS the moved leaf.
        local tab_id = state.next_tab_id
        state.next_tab_id = tab_id + 1
        ---@type Tab
        local new_tab = {
            id = tab_id,
            root = src_leaf,
            last_focused_id = src_leaf.id,
        }
        -- Placement: insert at anchor + 1 (right of the focused tab). When
        -- state.tabs is empty (no-op in practice under current guards, but
        -- encoded for safety), the new tab becomes the only tab at index 1.
        local insert_idx = placement_index()
        table.insert(state.tabs, insert_idx, new_tab)

        if was_active and follow_focus then
            -- Use the captured (pre-mutation) anchor, not #state.tabs. The
            -- new tab lives at insert_idx; set_active_tab_index handles
            -- zoom save/restore on the old tab, picks the new tab's
            -- last_focused_id, and fires update_pty_focus.
            set_active_tab_index(insert_idx)
        end
        -- When the source tab was inactive OR the caller opted out of focus-
        -- follow: state.active_tab is preserved. Insert at anchor + 1 always
        -- lands to the RIGHT of the active tab (insert_idx = active_tab + 1
        -- after normalization), so inserting doesn't shift the active tab's
        -- index — it stays at the same position in state.tabs and still
        -- resolves to the same logical tab. state.focused_id still refers
        -- to a pane in the still-active tab — in the inactive case, not the
        -- moved pane by invariant; in the opt-out case, the focused pane is
        -- a sibling of the moved pane in the (still-active) source tab. No
        -- focus mutation needed either way.

        prise.save()
        prise.request_frame()
        return true
    elseif event.type == "cwd_changed" then
        -- CWD changed for a PTY - update cached git branch
        update_cached_git_branch()
        prise.request_frame()
        prise.save() -- Auto-save on cwd change
    elseif event.type == "break_pane_request" then
        -- Server-asked-broker entry: classify + apply + reply via
        -- prise.notify("break_pane_reply", ...). The handler builds the
        -- inner break_pane data table from primitives only, keeping the
        -- cross-session bomb at :3380 (formerly :3317) asleep.
        M.handle_break_pane_request(event.data.pty_id, event.data.focus, event.data.request_id)
    elseif event.type == "break_pane_applied" then
        -- Convergence entry: re-apply the broker's break_pane locally
        -- so this client's tile-tree mirror catches up. The broker is
        -- excluded server-side, so this branch never fires on the broker.
        M.handle_break_pane_applied(event.data.pty_id, event.data.focus)
    end
end

---Recursive rendering function
---@param node Node
---@param force_unfocused? boolean
---@return table
local function render_node(node, force_unfocused)
    if is_pane(node) then
        local is_focused = (node.id == state.focused_id) and not (force_unfocused == true)
        prise.log.debug(
            "render_node: force_unfocused=" .. tostring(force_unfocused) .. " is_focused=" .. tostring(is_focused)
        )
        local terminal = prise.Terminal({
            pty = node.pty,
            ratio = node.ratio,
            focus = is_focused,
        })

        -- Wrap in Box if borders should be shown (only in box mode)
        if should_show_borders() and config.borders.mode == "box" then
            local border_color = is_focused and config.borders.focused_color or config.borders.unfocused_color

            return prise.Box({
                border = config.borders.style,
                style = { fg = border_color },
                child = terminal,
                ratio = node.ratio, -- Propagate ratio for layout system
            })
        else
            return terminal
        end
    elseif is_split(node) then
        local children_widgets = {}

        -- In separator mode, insert separators between children
        if should_show_borders() and config.borders.mode == "separator" then
            for i, child in ipairs(node.children) do
                -- Add separator before this child (except for first)
                if i > 1 then
                    -- Determine separator color based on adjacency to focused pane
                    local prev_child = node.children[i - 1]
                    local prev_focused = contains_focused(prev_child)
                    local curr_focused = contains_focused(child)
                    local sep_color = (prev_focused or curr_focused) and config.borders.focused_color
                        or config.borders.unfocused_color

                    local sep_axis = node.direction == "row" and "vertical" or "horizontal"
                    table.insert(
                        children_widgets,
                        prise.Separator({
                            axis = sep_axis,
                            style = { fg = sep_color },
                            border = config.borders.style,
                        })
                    )
                end
                table.insert(children_widgets, render_node(child, force_unfocused))
            end
        else
            -- Box mode or no borders: just render children directly
            for _, child in ipairs(node.children) do
                table.insert(children_widgets, render_node(child, force_unfocused))
            end
        end

        local props = {
            children = children_widgets,
            ratio = node.ratio,
            id = node.split_id,
            cross_axis_align = "stretch",
            resizable = true,
        }

        if node.direction == "row" then
            return prise.Row(props)
        else
            return prise.Column(props)
        end
    else
        error("render_node: unknown node type: " .. tostring(node.type))
    end
end

---Format a command palette item with name and right-aligned shortcut
---@param name string
---@param shortcut? string
---@param width number
---@return string
local function format_palette_item(name, shortcut, width)
    if not shortcut then
        return name
    end
    local padding = width - prise.gwidth(name) - prise.gwidth(shortcut)
    if padding < 2 then
        padding = 2
    end
    return name .. string.rep(" ", padding) .. shortcut
end

---Build the command palette overlay
---@return table?
local function build_palette()
    if not state.palette.visible or not state.palette.input then
        state.palette.regions = {}
        return nil
    end

    local text = state.palette.input:text()
    prise.log.debug("build_palette: text='" .. text .. "'")
    local filtered = filter_commands(text)
    local has_commands = #filtered > 0
    if not has_commands then
        table.insert(filtered, { name = "No matches" })
    end
    prise.log.debug("build_palette: filtered count=" .. #filtered)

    local items = {}
    for _, cmd in ipairs(filtered) do
        local cmd_name = cmd.name
        if type(cmd_name) == "function" then
            cmd_name = cmd_name()
        end
        ---@cast cmd_name string
        table.insert(items, format_palette_item(cmd_name, cmd.shortcut, PALETTE_INNER_WIDTH))
    end

    local palette_style = { bg = THEME.bg1, fg = THEME.fg_bright }
    local selected_style = { bg = THEME.accent, fg = THEME.fg_dark }
    local input_style = { bg = THEME.bg1, fg = THEME.fg_bright }

    -- Calculate click regions for visible items only (skip if no real commands)
    -- Palette layout: y=5, padding top=1, text input=1 line, separator=1 line
    -- Items start at y = 5 + 1 + 1 + 1 = 8
    local items_start_y = state.palette.palette_y + 1 + 1 + 1
    state.palette.regions = {}
    if has_commands then
        -- Calculate visible height: screen height minus palette header and padding
        -- Subtract: palette_y (5) + padding (2) + input (1) + separator (1) + bottom padding (1)
        local available_height = math.max(1, state.screen_rows - items_start_y - 1)
        local visible_count = math.min(#items - state.palette.scroll_offset, available_height)
        for display_row = 1, visible_count do
            local item_index = state.palette.scroll_offset + display_row
            table.insert(state.palette.regions, {
                start_y = items_start_y + (display_row - 1),
                end_y = items_start_y + display_row,
                index = item_index,
            })
        end
    end

    return prise.Positioned({
        anchor = "top_center",
        y = state.palette.palette_y,
        child = prise.Box({
            border = "none",
            max_width = PALETTE_WIDTH,
            style = palette_style,
            child = prise.Padding({
                top = 1,
                bottom = 1,
                left = 2,
                right = 2,
                child = prise.Column({
                    cross_axis_align = "stretch",
                    children = {
                        prise.TextInput({
                            input = state.palette.input,
                            style = input_style,
                        }),
                        prise.Text({
                            text = string.rep("─", PALETTE_WIDTH),
                            style = { fg = THEME.bg3, bg = THEME.bg1 },
                        }),
                        prise.List({
                            items = items,
                            selected = state.palette.selected,
                            scroll_offset = state.palette.scroll_offset,
                            style = palette_style,
                            selected_style = selected_style,
                        }),
                    },
                }),
            }),
        }),
    })
end

---Build the rename session overlay
---@return table?
local function build_rename()
    if not state.rename.visible or not state.rename.input then
        return nil
    end

    local palette_style = { bg = THEME.bg1, fg = THEME.fg_bright }
    local input_style = { bg = THEME.bg1, fg = THEME.fg_bright }

    return prise.Positioned({
        anchor = "top_center",
        y = 5,
        child = prise.Box({
            border = "none",
            max_width = PALETTE_WIDTH,
            style = palette_style,
            child = prise.Padding({
                top = 1,
                bottom = 1,
                left = 2,
                right = 2,
                child = prise.Column({
                    cross_axis_align = "stretch",
                    children = {
                        prise.Text({ text = "Rename Session", style = { fg = THEME.fg_dim, bg = THEME.bg1 } }),
                        prise.TextInput({
                            input = state.rename.input,
                            style = input_style,
                        }),
                    },
                }),
            }),
        }),
    })
end

---Build the rename tab modal
---@return table?
local function build_rename_tab()
    if not state.rename_tab.visible or not state.rename_tab.input then
        return nil
    end

    local palette_style = { bg = THEME.bg1, fg = THEME.fg_bright }
    local input_style = { bg = THEME.bg1, fg = THEME.fg_bright }

    return prise.Positioned({
        anchor = "top_center",
        y = 5,
        child = prise.Box({
            border = "none",
            max_width = PALETTE_WIDTH,
            style = palette_style,
            child = prise.Padding({
                top = 1,
                bottom = 1,
                left = 2,
                right = 2,
                child = prise.Column({
                    cross_axis_align = "stretch",
                    children = {
                        prise.Text({ text = "Rename Tab", style = { fg = THEME.fg_dim, bg = THEME.bg1 } }),
                        prise.TextInput({
                            input = state.rename_tab.input,
                            style = input_style,
                        }),
                    },
                }),
            }),
        }),
    })
end

---Build the session picker modal
---@return table?
local function build_session_picker()
    if not state.session_picker.visible or not state.session_picker.input then
        state.session_picker.regions = {}
        return nil
    end

    local text = state.session_picker.input:text()
    local filtered = filter_sessions(text)
    local has_sessions = #filtered > 0

    local items = {}
    local current_session = prise.get_session_name()
    for _, session in ipairs(filtered) do
        local display = session
        if session == current_session then
            display = session .. " (current)"
        end
        table.insert(items, display)
    end

    if not has_sessions then
        table.insert(items, "No sessions found")
    end

    local palette_style = { bg = THEME.bg1, fg = THEME.fg_bright }
    local selected_style = { bg = THEME.accent, fg = THEME.fg_dark }
    local input_style = { bg = THEME.bg1, fg = THEME.fg_bright }

    -- Calculate click regions for visible items
    local items_start_y = 5 + 1 + 1 + 1 -- palette_y + padding + input + separator
    state.session_picker.regions = {}
    if has_sessions then
        local available_height = math.max(1, state.screen_rows - items_start_y - 1)
        local visible_count = math.min(#items - state.session_picker.scroll_offset, available_height)
        for display_row = 1, visible_count do
            local item_index = state.session_picker.scroll_offset + display_row
            table.insert(state.session_picker.regions, {
                start_y = items_start_y + (display_row - 1),
                end_y = items_start_y + display_row,
                index = item_index,
            })
        end
    end

    return prise.Positioned({
        anchor = "top_center",
        y = 5,
        focus = true,
        child = prise.Box({
            border = "none",
            max_width = PALETTE_WIDTH,
            style = palette_style,
            focus = true,
            child = prise.Padding({
                top = 1,
                bottom = 1,
                left = 2,
                right = 2,
                child = prise.Column({
                    cross_axis_align = "stretch",
                    children = {
                        prise.Text({ text = "Switch Session", style = { fg = THEME.fg_dim, bg = THEME.bg1 } }),
                        prise.Padding({
                            left = 38,
                            child = prise.Text({
                                text = "Shift + R - rename",
                                style = { fg = THEME.fg_dim, bg = THEME.bg1 },
                            }),
                        }),
                        prise.Padding({
                            left = 38,
                            child = prise.Text({
                                text = "Shift + D - delete",
                                style = { fg = THEME.fg_dim, bg = THEME.bg1 },
                            }),
                        }),
                        prise.TextInput({
                            input = state.session_picker.input,
                            style = input_style,
                            focus = true,
                        }),
                        prise.Text({
                            text = string.rep("─", PALETTE_WIDTH),
                            style = { fg = THEME.bg3, bg = THEME.bg1 },
                        }),
                        prise.List({
                            items = items,
                            selected = state.session_picker.selected,
                            scroll_offset = state.session_picker.scroll_offset,
                            style = palette_style,
                            selected_style = selected_style,
                        }),
                    },
                }),
            }),
        }),
    })
end

---Build the layout picker modal
---@return table?
local function build_layout_picker()
    if not state.layout_picker.visible then
        state.layout_picker.regions = {}
        return nil
    end

    local names = get_layout_names()
    if #names == 0 then
        close_layout_picker()
        return nil
    end

    local items = {}
    for _, name in ipairs(names) do
        local layout = config.layouts[name]
        local tab_count = #layout.tabs
        local pane_count = count_layout_total_panes(layout)
        local desc = string.format("%s (%d tabs, %d panes)", name, tab_count, pane_count)
        table.insert(items, desc)
    end

    local palette_style = { bg = THEME.bg1, fg = THEME.fg_bright }
    local selected_style = { bg = THEME.accent, fg = THEME.fg_dark }

    local items_start_y = 5 + 1 + 1 + 1
    state.layout_picker.regions = {}
    local available_height = math.max(1, state.screen_rows - items_start_y - 1)
    local visible_count = math.min(#items - state.layout_picker.scroll_offset, available_height)
    for display_row = 1, visible_count do
        local item_index = state.layout_picker.scroll_offset + display_row
        table.insert(state.layout_picker.regions, {
            start_y = items_start_y + (display_row - 1),
            end_y = items_start_y + display_row,
            index = item_index,
        })
    end

    return prise.Positioned({
        anchor = "top_center",
        y = 5,
        focus = true,
        child = prise.Box({
            border = "none",
            max_width = PALETTE_WIDTH,
            style = palette_style,
            focus = true,
            child = prise.Padding({
                top = 1,
                bottom = 1,
                left = 2,
                right = 2,
                child = prise.Column({
                    cross_axis_align = "stretch",
                    children = {
                        prise.Text({ text = "Layouts", style = { fg = THEME.fg_dim, bg = THEME.bg1 } }),
                        prise.Text({
                            text = string.rep("─", PALETTE_WIDTH),
                            style = { fg = THEME.bg3, bg = THEME.bg1 },
                        }),
                        prise.List({
                            items = items,
                            selected = state.layout_picker.selected,
                            scroll_offset = state.layout_picker.scroll_offset,
                            style = palette_style,
                            selected_style = selected_style,
                        }),
                    },
                }),
            }),
        }),
    })
end

---Resolve the display title for a tab
---@param tab Tab
---@param is_active boolean
---@return string
local function get_tab_title(tab, is_active)
    ---@type string
    local result = "Terminal"
    if tab.title then
        ---@diagnostic disable-next-line: cast-type-mismatch
        result = tostring(tab.title)
    else
        local focused_id = is_active and state.focused_id or tab.last_focused_id
        if focused_id and tab.root then
            local path = find_node_path(tab.root, focused_id)
            if path then
                local pane = path[#path]
                local pty_title = pane.pty:title()
                if pty_title and #pty_title > 0 then
                    result = pty_title
                else
                    local cwd = pane.pty:cwd()
                    if cwd then
                        result = cwd:match("([^/]+)/?$") or cwd
                    end
                end
            end
        end
    end
    ---@diagnostic disable-next-line: return-type-mismatch
    return result
end

---Build tab bar with default design (rounded pill style)
---@return table
local function build_tab_bar_default()
    local num_tabs = #state.tabs
    local total_width = state.screen_cols
    local endcap_width = 2 -- left_round and right_round are 1 cell each

    -- Calculate tab widths: divide available space evenly
    local base_tab_width = math.floor(total_width / num_tabs)
    local extra_pixels = total_width % num_tabs

    local segments = {}
    local x_pos = 0
    state.tab_regions = {}
    state.tab_close_regions = {}

    for i, tab in ipairs(state.tabs) do
        local is_active = (i == state.active_tab)
        local is_hovered = (i == state.hovered_tab)
        local is_close_hovered = (i == state.hovered_close_tab)

        -- Distribute extra width to last tabs so they fill the line
        local tab_width = base_tab_width
        if i > (num_tabs - extra_pixels) then
            tab_width = tab_width + 1
        end

        -- Close widget: always reserve 2 cells, only show icon when hovered
        local close_widget_width = 2
        local close_text = "  " -- 2 spaces when not hovered
        if is_close_hovered then
            close_text = "\u{F530}" -- md-close_circle (filled)
        elseif is_hovered then
            close_text = "\u{F467}" -- md-close_circle_outline
        end
        -- Pad close_text to exactly close_widget_width cells
        local close_text_width = prise.gwidth(close_text)
        if close_text_width < close_widget_width then
            close_text = close_text .. string.rep(" ", close_widget_width - close_text_width)
        end

        -- Get title
        local title = get_tab_title(tab, is_active)

        -- Tab index shown on the right
        local index_str = tostring(i)
        local index_width = #index_str + 2 -- space + index + space

        -- Always reserve space for endcaps, close widget, and index
        local inner_width = tab_width - endcap_width - close_widget_width - index_width
        local title_width = prise.gwidth(title)

        -- Truncate title if needed
        if title_width > inner_width then
            title = string.sub(title, 1, inner_width - 1) .. "…"
            title_width = prise.gwidth(title)
        end

        -- Center the title
        local padding_total = inner_width - title_width
        local pad_left = math.floor(padding_total / 2)
        local pad_right = padding_total - pad_left
        if pad_left < 0 then
            pad_left = 0
        end
        if pad_right < 0 then
            pad_right = 0
        end

        local label = string.rep(" ", pad_left) .. title .. string.rep(" ", pad_right)
        local index_label = " " .. index_str .. " "

        -- Record close button hit region (after left endcap)
        local close_start = x_pos + 1 -- after left endcap
        table.insert(state.tab_close_regions, {
            start_x = close_start,
            end_x = close_start + close_widget_width,
            tab_index = i,
        })

        -- Record hit region for this tab
        table.insert(state.tab_regions, {
            start_x = x_pos,
            end_x = x_pos + tab_width,
            tab_index = i,
        })
        x_pos = x_pos + tab_width

        local tab_bg, tab_fg
        if is_active then
            tab_bg = THEME.bg4
            tab_fg = THEME.fg_bright
        elseif is_hovered then
            tab_bg = THEME.bg3
            tab_fg = THEME.fg_bright
        else
            tab_bg = THEME.bg2
            tab_fg = THEME.fg_dim
        end

        -- Left endcap
        table.insert(segments, { text = POWERLINE_SYMBOLS.left_round, style = { fg = tab_bg, bg = THEME.bg1 } })
        -- Close widget
        table.insert(segments, { text = close_text, style = { bg = tab_bg, fg = tab_fg } })
        -- Tab content (title)
        table.insert(segments, { text = label, style = { bg = tab_bg, fg = tab_fg, bold = is_active } })
        -- Tab index (right side, dimmed)
        table.insert(segments, { text = index_label, style = { bg = tab_bg, fg = THEME.fg_dim } })
        -- Right endcap
        table.insert(segments, { text = POWERLINE_SYMBOLS.right_round, style = { fg = tab_bg, bg = THEME.bg1 } })
    end

    return segments
end

---@return TabInfo[]
local function build_custom_tab_infos()
    local tab_infos = {}
    for i, tab in ipairs(state.tabs) do
        local title = get_tab_title(tab, i == state.active_tab)
        local is_explicit = tab.title ~= nil

        if config.tab_bar.format_title and not is_explicit then
            title = config.tab_bar.format_title(title, i)
        end

        table.insert(tab_infos, {
            index = i,
            title = title,
            is_explicit_title = is_explicit,
            is_active = (i == state.active_tab),
            is_hovered = (i == state.hovered_tab),
            is_close_hovered = (i == state.hovered_close_tab),
            pane_count = count_tab_panes(tab),
            is_zoomed = (i == state.active_tab and state.zoomed_pane_id ~= nil)
                or (i ~= state.active_tab and tab.zoomed_pane_id ~= nil),
        })
    end

    return tab_infos
end

---Compute the focus-centre windowing offset into the tab strip.
---Pure function: takes tab widths + active index + cell budget, returns the
---start offset (cells from left of the full strip) and total width. Mirrors
---tmux's `format_draw_put_list`: when the strip overflows the budget, centre
---the active tab in the window; when the focus-centre minus half-budget would
---underflow, clamp start to 0; when it would overrun the tail, clamp to the
---max.
---@param tab_widths integer[]
---@param active_idx integer 1-based; out-of-range → treated as 1.
---@param budget integer Cell budget for tabs. Non-positive → treated as 1.
---@return { start: integer, total_width: integer }
local function compute_focus_window(tab_widths, active_idx, budget)
    local n = #tab_widths
    if n == 0 then
        return { start = 0, total_width = 0 }
    end
    local cols = (budget and budget >= 1) and budget or 1

    -- Total strip width = sum(label_widths) + (N-1) core-injected separators.
    local total_width = 0
    for i = 1, n do
        local w = tab_widths[i] or 0
        if w < 0 then
            w = 0
        end
        total_width = total_width + w
    end
    if n > 1 then
        total_width = total_width + (n - 1)
    end

    if total_width <= cols then
        return { start = 0, total_width = total_width }
    end

    local a = active_idx
    if type(a) ~= "number" or a < 1 or a > n then
        a = 1
    end

    -- Focus-start accounts for separators between tabs 1..a-1.
    local focus_start = 0
    for i = 1, a - 1 do
        local w = tab_widths[i] or 0
        if w < 0 then
            w = 0
        end
        focus_start = focus_start + w + 1 -- +1 for the separator after tab i
    end
    local active_w = tab_widths[a] or 0
    if active_w < 0 then
        active_w = 0
    end
    local focus_end = focus_start + active_w
    local focus_centre = focus_start + math.floor((focus_end - focus_start) / 2)

    -- Explicit underflow branch — not a post-hoc math.max clamp. See risks.
    local half = math.floor(cols / 2)
    local start
    if focus_centre >= half then
        start = focus_centre - half
    else
        start = 0
    end
    local max_start = total_width - cols
    if max_start < 0 then
        max_start = 0
    end
    if start > max_start then
        start = max_start
    end

    return { start = start, total_width = total_width }
end

---Cumulative label-start cell of tab `idx` (1-based), accounting for the
---core-injected separators between each prior adjacent pair. Local helper
---for the visible-range math; separator width is hard-coded to 1 cell.
---@param tab_widths integer[]
---@param idx integer
---@return integer
local function cum_label_start(tab_widths, idx)
    local c = 0
    for i = 1, idx - 1 do
        local w = tab_widths[i] or 0
        if w < 0 then
            w = 0
        end
        c = c + w + 1 -- +1 for the separator between tab i and tab i+1
    end
    return c
end

---Walk cumulative widths to derive the 1-based inclusive visible tab range
---plus the leading/trailing cell clips for the boundary tabs. Accounts for
---the core-injected 1-cell inter-tab separator (never before first, never
---after last). Honors the snap-past-separator rule: if `start` lands in a
---separator cell, advance to the next tab's first cell; if `window_end`
---lands in a separator cell, clip back to the previous tab's last cell.
---@param tab_widths integer[] Label-only widths; separators added internally.
---@param start integer Cells from left of the full strip where window begins.
---@param effective_budget integer Cell width of the (gutter-adjusted) window.
---@return { first_idx: integer, last_idx: integer, leading_clip: integer, trailing_clip: integer }
local function derive_visible_range(tab_widths, start, effective_budget)
    local n = #tab_widths
    if n == 0 or effective_budget <= 0 then
        return { first_idx = 0, last_idx = 0, leading_clip = 0, trailing_clip = 0 }
    end

    local window_end = start + effective_budget
    local first_idx, last_idx = nil, nil
    local first_cum_start, last_cum_end = 0, 0
    local cursor = 0
    for i = 1, n do
        local w = tab_widths[i] or 0
        if w < 0 then
            w = 0
        end
        if cursor + w > start and cursor < window_end then
            if not first_idx then
                first_idx = i
                first_cum_start = cursor
            end
            last_idx = i
            last_cum_end = cursor + w
        end
        cursor = cursor + w + (i < n and 1 or 0)
    end

    if not first_idx then
        return { first_idx = 0, last_idx = 0, leading_clip = 0, trailing_clip = 0 }
    end

    local leading_clip = math.max(0, start - first_cum_start)
    local trailing_clip = math.max(0, last_cum_end - window_end)

    -- Snap-past-separator (left): leading clip consumed the whole first tab
    -- → `start` sat inside the following separator cell. Advance to next tab.
    local first_w = tab_widths[first_idx] or 0
    if first_w > 0 and leading_clip >= first_w and first_idx < last_idx then
        first_idx = first_idx + 1
        first_cum_start = cum_label_start(tab_widths, first_idx)
        leading_clip = math.max(0, start - first_cum_start)
    end

    -- Snap-past-separator (right): trailing clip consumed the whole last tab
    -- → `window_end` sat inside the preceding separator cell. Clip back.
    local last_w = tab_widths[last_idx] or 0
    if last_w > 0 and trailing_clip >= last_w and first_idx < last_idx then
        last_idx = last_idx - 1
        local w = tab_widths[last_idx] or 0
        if w < 0 then
            w = 0
        end
        last_cum_end = cum_label_start(tab_widths, last_idx) + w
        trailing_clip = math.max(0, last_cum_end - window_end)
    end

    return {
        first_idx = first_idx,
        last_idx = last_idx,
        leading_clip = leading_clip,
        trailing_clip = trailing_clip,
    }
end

---Decide whether to show the left/right gutter glyphs and narrow the tab
---window to make room for them. Gutters appear only when tabs are hidden on
---that side. If the combined gutter width exceeds budget, drop both.
---@param start integer
---@param effective_budget integer
---@param total_width integer
---@param gutter_left_w integer
---@param gutter_right_w integer
---@return { show_left: boolean, show_right: boolean, adjusted_start: integer, adjusted_budget: integer }
local function apply_gutters(start, effective_budget, total_width, gutter_left_w, gutter_right_w)
    local show_left = start > 0
    local show_right = (start + effective_budget) < total_width

    -- Narrow-terminal guard: if we couldn't fit the glyphs plus at least one
    -- cell of tab, drop both gutters rather than let them dominate.
    if effective_budget < gutter_left_w + gutter_right_w + 1 then
        show_left = false
        show_right = false
    end

    local left_w = show_left and gutter_left_w or 0
    local right_w = show_right and gutter_right_w or 0
    local adjusted_budget = effective_budget - left_w - right_w
    if adjusted_budget < 0 then
        adjusted_budget = 0
    end
    local adjusted_start = start + left_w

    return {
        show_left = show_left,
        show_right = show_right,
        adjusted_start = adjusted_start,
        adjusted_budget = adjusted_budget,
    }
end

---Clip a boundary tab's segments by cell-precise leading/trailing counts via
---`prise.cell_substring`. Flattens segments into a single string for the
---slice, preserving the first segment's style on the returned segment.
---@param segments table[] Array of `{ text = string, style = table? }`.
---@param leading_clip_cells integer
---@param trailing_clip_cells integer
---@return table[] Single-entry segment list (or empty array if the clip empties it).
local function clip_boundary_tab(segments, leading_clip_cells, trailing_clip_cells)
    if not segments or #segments == 0 then
        return {}
    end
    local parts = {}
    for _, seg in ipairs(segments) do
        parts[#parts + 1] = seg.text or ""
    end
    local flat = table.concat(parts)
    local total_cells = prise.gwidth(flat)

    if leading_clip_cells > 0 then
        flat = prise.cell_substring(flat, leading_clip_cells, total_cells)
    end
    if trailing_clip_cells > 0 then
        local current = prise.gwidth(flat)
        local new_end = current - trailing_clip_cells
        if new_end < 0 then
            new_end = 0
        end
        flat = prise.cell_substring(flat, 0, new_end)
    end

    local style = segments[1] and segments[1].style or {}
    return { { text = flat, style = style } }
end

---True when `v` is a segment list (array of `{text=...}` entries) rather than
---a single segment. Distinguishes `{text="x"}` (single) from `{{text="x"}}`
---(list) by the presence of a `text` field at the top level.
---@param v table
---@return boolean
local function is_segment_list(v)
    return v[1] ~= nil and v.text == nil
end

---Append a gutter slot's segments — accepts either a single segment or a list
---of segments. Nil skips entirely.
---@param out table[]
---@param slot table|table[]|nil
local function append_gutter_slot(out, slot)
    if slot == nil then
        return
    end
    if is_segment_list(slot) then
        for _, s in ipairs(slot) do
            out[#out + 1] = s
        end
    else
        out[#out + 1] = slot
    end
end

---Concatenate prefix + optional left gutter + visible-tab segments + optional
---right gutter + suffix into a single flat segment list for `prise.Text`. A
---single-cell `" "` separator is injected between each adjacent pair of
---visible tabs (never before the first, never after the last). Zero-width
---boundary tabs (label clipped to 0 cells) get no adjacent separator on
---their inner side — the snap-past-separator rule in `derive_visible_range`
---prevents this shape from arising, and we defensively skip separators next
---to empty tab segment lists here too.
---Gutter slots accept single segment OR segment list (renderer-owned gutters).
---@param prefix_segs table[]
---@param gutter_l_seg table|table[]|nil nil to skip
---@param visible_tab_segs_list table[][] Array of each visible tab's segments.
---@param gutter_r_seg table|table[]|nil nil to skip
---@param suffix_segs table[]
---@return table[]
local function compose_layout_segments(prefix_segs, gutter_l_seg, visible_tab_segs_list, gutter_r_seg, suffix_segs)
    local out = {}
    for _, s in ipairs(prefix_segs or {}) do
        out[#out + 1] = s
    end
    append_gutter_slot(out, gutter_l_seg)
    local tab_list = visible_tab_segs_list or {}
    for i, tab_segs in ipairs(tab_list) do
        if i > 1 and #tab_segs > 0 and #tab_list[i - 1] > 0 then
            out[#out + 1] = { text = " ", style = {} }
        end
        for _, s in ipairs(tab_segs) do
            out[#out + 1] = s
        end
    end
    append_gutter_slot(out, gutter_r_seg)
    for _, s in ipairs(suffix_segs or {}) do
        out[#out + 1] = s
    end
    return out
end

---Walk the visible tabs and emit on-screen click regions keyed by each tab's
---original `tab_index`. x-offset starts at `prefix_w + gutter_l_w`; advances
---by `tab.width + 1` between visible tabs (the core-injected inter-tab
---separator) and by `tab.width` on the last. Gutters and separator cells are
---NOT clickable — half-open semantics (`start_x` inclusive, `end_x` exclusive)
---keep separator cells out of every region.
---@param prefix_w integer
---@param gutter_l_w integer 0 when the left gutter is hidden.
---@param visible_tabs { tab_index: integer, width: integer }[]
---@param gutter_r_w integer Unused in x-math but documents the layout.
---@return { start_x: integer, end_x: integer, tab_index: integer }[]
local function derive_click_regions(prefix_w, gutter_l_w, visible_tabs, gutter_r_w)
    local _ = gutter_r_w -- doc only
    local tabs = visible_tabs or {}
    local regions = {}
    local x = prefix_w + gutter_l_w
    for i, tab in ipairs(tabs) do
        regions[#regions + 1] = {
            start_x = x,
            end_x = x + tab.width,
            tab_index = tab.tab_index,
        }
        -- Advance past the tab; inject separator spacing between adjacent tabs
        -- (never after the last). Zero-width tabs contribute no separator.
        x = x + tab.width
        if i < #tabs and tab.width > 0 and tabs[i + 1].width > 0 then
            x = x + 1
        end
    end
    return regions
end

---Measure a tab's on-screen cell width by concatenating its segments' text.
---Local helper — not exposed; tests drive the segment layout directly.
---@param segments table[]
---@return integer
local function measure_tab_segments(segments)
    local n = 0
    for _, seg in ipairs(segments or {}) do
        n = n + prise.gwidth(seg.text or "")
    end
    return n
end

---Emit a gutter segment from a plain-string config value. Returns nil when
---the config value is absent or empty — caller treats nil as "no gutter".
---Width is derived via `prise.gwidth`. Default-renderer fallback only; the
---styled-segment form used to live here and is now expressed through the
---renderer's `TabBarLayout.gutter_left`/`gutter_right` fields instead.
---@param gutter_cfg string|nil
---@return table? segment, integer width
local function build_gutter_segment(gutter_cfg)
    if gutter_cfg == nil or gutter_cfg == "" then
        return nil, 0
    end
    if type(gutter_cfg) == "string" then
        return { text = gutter_cfg, style = {} }, prise.gwidth(gutter_cfg)
    end
    return nil, 0
end

---Warn-once (latched on `state.tab_bar_render_warned`) + return an empty
---composed strip for malformed renderer output or runtime errors. Keeps the
---tab bar blank for the rest of the session rather than flickering warns.
---@param msg string
---@param prefix_segs table[]?
---@param suffix_segs table[]?
---@return table[]
local function degraded_tab_bar(msg, prefix_segs, suffix_segs)
    if not state.tab_bar_render_warned then
        state.tab_bar_render_warned = true
        prise.log.warn(msg)
    end
    state.tab_regions = {}
    state.tab_close_regions = {}
    -- Compose prefix + suffix when they're structurally valid; callers pass
    -- nil when even that isn't safe.
    return compose_layout_segments(prefix_segs or {}, nil, {}, nil, suffix_segs or {})
end

---Validate a single segment shape: table with string `text` and optional
---table `style`. Returns nil on success or a reason string on failure.
---@param seg any
---@return string?
local function validate_segment_shape(seg)
    if type(seg) ~= "table" then
        return "not a table"
    end
    if type(seg.text) ~= "string" then
        return "segment.text not a string"
    end
    if seg.style ~= nil and type(seg.style) ~= "table" then
        return "segment.style not a table"
    end
    return nil
end

---Validate an optional gutter-slot value: either a single segment or a list
---of segments (array where each entry passes `validate_segment_shape`).
---Nil is accepted by the caller — this only runs when the field is present.
---@param gutter any
---@param field_name string For error context ("gutter_left" / "gutter_right").
---@return string?
local function validate_gutter_field(gutter, field_name)
    if type(gutter) ~= "table" then
        return "render()." .. field_name .. " not a table"
    end
    -- List form: detect via numeric first entry with no top-level `text`.
    if gutter[1] ~= nil and gutter.text == nil then
        for i, seg in ipairs(gutter) do
            local bad = validate_segment_shape(seg)
            if bad then
                return "render()." .. field_name .. "[" .. tostring(i) .. "] " .. bad
            end
        end
        return nil
    end
    -- Single-segment form.
    local bad = validate_segment_shape(gutter)
    if bad then
        return "render()." .. field_name .. " " .. bad
    end
    return nil
end

---Validate the layout shape returned by the custom renderer. Returns a
---reason string on failure or nil on success.
---@param layout any
---@return string?
local function validate_tab_bar_layout(layout)
    if type(layout) ~= "table" then
        return "render() returned non-table"
    end
    if type(layout.prefix) ~= "table" then
        return "render().prefix not a table"
    end
    if type(layout.tabs) ~= "table" then
        return "render().tabs not a table"
    end
    if type(layout.suffix) ~= "table" then
        return "render().suffix not a table"
    end
    for i, tab in ipairs(layout.tabs) do
        if
            type(tab) ~= "table"
            or type(tab.tab_index) ~= "number"
            or math.floor(tab.tab_index) ~= tab.tab_index
            or type(tab.label_segments) ~= "table"
        then
            return "render().tabs[" .. tostring(i) .. "] malformed"
        end
    end
    -- All-or-nothing gutters: asymmetric presence is malformed. Renderer
    -- proposes both sides; core decides which to show via overflow gate.
    local has_left = layout.gutter_left ~= nil
    local has_right = layout.gutter_right ~= nil
    if has_left ~= has_right then
        return "render() gutter_left/gutter_right must both be set or both absent"
    end
    if has_left then
        local bad_l = validate_gutter_field(layout.gutter_left, "gutter_left")
        if bad_l then
            return bad_l
        end
        local bad_r = validate_gutter_field(layout.gutter_right, "gutter_right")
        if bad_r then
            return bad_r
        end
    end
    return nil
end

---Slice `tabs` by visible range, clip boundary tabs by cell-precise leading /
---trailing counts, and emit the flattened segment list + per-tab click-region
---metadata. Local helper for `build_tab_bar_custom` — not exposed. Consumes
---`tab.label_segments` (label-only; inter-tab separators are core-injected).
---@param tabs { tab_index: integer, label_segments: table[] }[]
---@param tab_widths integer[]
---@param vr { first_idx: integer, last_idx: integer, leading_clip: integer, trailing_clip: integer }
---@return table[][] visible_tab_segs_list, { tab_index: integer, width: integer }[] visible_tabs_meta
local function slice_and_clip_visible(tabs, tab_widths, vr)
    local segs_list = {}
    local meta = {}
    for i = vr.first_idx, vr.last_idx do
        local tab = tabs[i]
        local segs = tab.label_segments
        local lead = (i == vr.first_idx) and vr.leading_clip or 0
        local trail = (i == vr.last_idx) and vr.trailing_clip or 0
        local width = tab_widths[i] - lead - trail
        if width < 0 then
            width = 0
        end
        if lead > 0 or trail > 0 then
            segs = clip_boundary_tab(segs, lead, trail)
        end
        segs_list[#segs_list + 1] = segs
        meta[#meta + 1] = { tab_index = tab.tab_index, width = width }
    end
    return segs_list, meta
end

---Measure a gutter slot's cell width when the renderer emits a segment or a
---segment list. Mirrors `measure_tab_segments` but accepts the single-segment
---shape too. Returns 0 for nil.
---@param slot table|table[]|nil
---@return integer
local function measure_gutter_slot(slot)
    if slot == nil then
        return 0
    end
    if slot[1] ~= nil and slot.text == nil then
        return measure_tab_segments(slot)
    end
    return prise.gwidth(slot.text or "")
end

---Pick gutter slots + widths for composition. Prefers renderer-owned gutters
---when the layout carries them (all-or-nothing, validator-enforced); falls
---back to the plain-string config glyphs otherwise.
---@param layout table Validated TabBarLayout.
---@return table|table[]|nil left_slot, table|table[]|nil right_slot, integer left_w, integer right_w
local function pick_gutter_slots(layout)
    if layout.gutter_left ~= nil then
        return layout.gutter_left,
            layout.gutter_right,
            measure_gutter_slot(layout.gutter_left),
            measure_gutter_slot(layout.gutter_right)
    end
    local left, left_w = build_gutter_segment(config.tab_bar.gutter_left)
    local right, right_w = build_gutter_segment(config.tab_bar.gutter_right)
    return left, right, left_w, right_w
end

---Build tab bar with custom renderer (structured layout).
---Contract: renderer returns `{ prefix, tabs, suffix, gutter_left?, gutter_right? }`
---where tabs is a list of `{ tab_index, label_segments }`. Core measures each
---tab's label-only width, centres the focus window (accounting for the core-
---injected 1-cell separators between adjacent visible tabs), decides gutter
---visibility by overflow, splices renderer-owned gutter segments verbatim
---(falling back to plain-string config glyphs when the renderer returns none),
---applies cell-precise boundary clipping, injects inter-tab separators, and
---emits click regions keyed by `tab_index`. Any renderer error / malformed
---layout → warn-once + empty strip (latched on `state.tab_bar_render_warned`).
---@return table[]
local function build_tab_bar_custom()
    state.tab_regions = {}
    state.tab_close_regions = {}

    local tab_infos = build_custom_tab_infos()
    local screen_cols = state.screen_cols
    if screen_cols < 1 then
        screen_cols = 1
    end

    local render_opts = {
        gutter_left = config.tab_bar.gutter_left or "",
        gutter_right = config.tab_bar.gutter_right or "",
    }
    local ok, layout = pcall(config.tab_bar.render, tab_infos, screen_cols, THEME, { scroll_offset = 0 }, render_opts)
    if not ok then
        return degraded_tab_bar("tab_bar.render raised: " .. tostring(layout))
    end
    local bad = validate_tab_bar_layout(layout)
    if bad then
        return degraded_tab_bar("tab_bar.render layout invalid: " .. bad)
    end

    local prefix_segs, tabs, suffix_segs = layout.prefix, layout.tabs, layout.suffix
    local prefix_w = measure_tab_segments(prefix_segs)
    local suffix_w = measure_tab_segments(suffix_segs)

    if prefix_w + suffix_w >= screen_cols then
        return compose_layout_segments(prefix_segs, nil, {}, nil, suffix_segs)
    end
    local tab_budget = screen_cols - prefix_w - suffix_w
    ---@cast tab_budget integer

    local tab_widths = {}
    for i, tab in ipairs(tabs) do
        tab_widths[i] = measure_tab_segments(tab.label_segments)
    end

    local active_idx = state.active_tab
    if type(active_idx) ~= "number" or active_idx < 1 or active_idx > #tabs then
        active_idx = 1
    end
    local fw = compute_focus_window(tab_widths, active_idx, tab_budget)

    local gutter_l_slot, gutter_r_slot, gutter_left_w, gutter_right_w = pick_gutter_slots(layout)
    local ag = apply_gutters(fw.start, tab_budget, fw.total_width, gutter_left_w, gutter_right_w)

    local vr = derive_visible_range(tab_widths, ag.adjusted_start, ag.adjusted_budget)
    if vr.first_idx == 0 then
        return compose_layout_segments(prefix_segs, nil, {}, nil, suffix_segs)
    end

    local visible_tab_segs_list, visible_tabs_meta = slice_and_clip_visible(tabs, tab_widths, vr)

    state.tab_regions = derive_click_regions(
        prefix_w,
        ag.show_left and gutter_left_w or 0,
        visible_tabs_meta,
        ag.show_right and gutter_right_w or 0
    )
    return compose_layout_segments(
        prefix_segs,
        ag.show_left and gutter_l_slot or nil,
        visible_tab_segs_list,
        ag.show_right and gutter_r_slot or nil,
        suffix_segs
    )
end

---Build the tab bar UI
---@return table?
local function build_tab_bar()
    if not config.tab_bar.show_single_tab and #state.tabs <= 1 then
        state.tab_regions = {}
        state.tab_close_regions = {}
        return nil
    end

    -- Use custom renderer if provided
    if config.tab_bar.render then
        local segments = build_tab_bar_custom()
        return prise.Text(segments)
    else
        local segments = build_tab_bar_default()
        return prise.Text(segments)
    end
end

---Build the powerline-style status bar
---@return table
local function build_status_bar()
    local mode_color = state.pending_command and THEME.mode_command or THEME.mode_normal
    local session_name = (prise.get_session_name() or "prise"):upper()
    local mode_text = state.pending_command and " CMD " or (" " .. session_name .. " ")

    -- Use cached git branch (updated on cwd_changed and focus change)
    local git_branch = state.cached_git_branch

    -- Get current time
    local time_str = prise.get_time()

    -- Build segments and track width
    local segments = {}
    local left_width = 0

    -- Mode indicator
    table.insert(segments, { text = mode_text, style = { bg = mode_color, fg = THEME.fg_dark, bold = true } })
    left_width = left_width + prise.gwidth(mode_text)

    -- Track the last background color for proper powerline transitions
    local last_bg = mode_color

    -- Git branch
    if git_branch then
        local branch_text = " \u{F062C} " .. git_branch .. " "
        table.insert(segments, { text = POWERLINE_SYMBOLS.right_solid, style = { fg = last_bg, bg = THEME.bg2 } })
        table.insert(segments, { text = branch_text, style = { bg = THEME.bg2, fg = THEME.fg_bright } })
        left_width = left_width + 1 + prise.gwidth(branch_text)
        last_bg = THEME.bg2
    end

    -- Zoom indicator
    if state.zoomed_pane_id then
        table.insert(segments, { text = POWERLINE_SYMBOLS.right_solid, style = { fg = last_bg, bg = THEME.yellow } })
        table.insert(segments, { text = " ZOOM ", style = { bg = THEME.yellow, fg = THEME.fg_dark, bold = true } })
        left_width = left_width + 1 + 6
        last_bg = THEME.yellow
    end

    -- Floating resize mode indicator
    if state.floating.resize_mode then
        local resize_text = " RESIZE " .. state.floating.width .. "x" .. state.floating.height .. " "
        table.insert(segments, { text = POWERLINE_SYMBOLS.right_solid, style = { fg = last_bg, bg = THEME.accent } })
        table.insert(segments, { text = resize_text, style = { bg = THEME.accent, fg = THEME.fg_dark, bold = true } })
        left_width = left_width + 1 + prise.gwidth(resize_text)
        last_bg = THEME.accent
    end

    -- End left side
    table.insert(segments, { text = POWERLINE_SYMBOLS.right_solid, style = { fg = last_bg, bg = THEME.bg1 } })
    left_width = left_width + 1

    -- Right side content
    local right_text = " " .. time_str .. " "
    local right_width = 1 + prise.gwidth(right_text) -- powerline symbol + time

    -- Calculate padding to fill the middle
    local padding = state.screen_cols - left_width - right_width
    if padding < 0 then
        padding = 0
    end

    -- Add padding
    table.insert(segments, { text = string.rep(" ", padding), style = { bg = THEME.bg1 } })

    -- Add right side
    table.insert(segments, { text = POWERLINE_SYMBOLS.left_solid, style = { fg = THEME.bg3, bg = THEME.bg1 } })
    table.insert(segments, { text = right_text, style = { bg = THEME.bg3, fg = THEME.fg_dim } })

    return prise.Text(segments)
end

---Schedule a clock timer to refresh the display every minute
local function schedule_clock_timer()
    if state.clock_timer or state.detaching then
        return
    end
    state.clock_timer = prise.set_timeout(60000, function()
        state.clock_timer = nil
        if not state.detaching then
            prise.request_frame()
            schedule_clock_timer()
        end
    end)
end

---Build the swap tab with index modal
---@return table|nil
local function build_swap_with_index()
    if not state.swap_with_index or not state.swap_with_index.visible or not state.swap_with_index.input then
        return nil
    end

    local palette_style = { bg = THEME.bg1, fg = THEME.fg_bright }
    local input_style = { bg = THEME.bg1, fg = THEME.fg_bright }

    return prise.Positioned({
        anchor = "top_center",
        y = 5,
        child = prise.Box({
            border = "none",
            max_width = PALETTE_WIDTH,
            style = palette_style,
            child = prise.Padding({
                top = 1,
                bottom = 1,
                left = 2,
                right = 2,
                child = prise.Column({
                    cross_axis_align = "stretch",
                    children = {
                        prise.Text({
                            text = "Swap Tab with Index (1-" .. #state.tabs .. ")",
                            style = { fg = THEME.fg_dim, bg = THEME.bg1 },
                        }),
                        prise.TextInput({
                            input = state.swap_with_index.input,
                            style = input_style,
                        }),
                    },
                }),
            }),
        }),
    })
end

local function build_floating()
    local tab = get_active_tab()
    if
        not tab
        or not tab.floating
        or not tab.floating.visible
        or not tab.floating.pane
        or not tab.floating.pane.pty
    then
        return nil
    end

    -- Create positioned terminal widget with size constraints
    return prise.Positioned({
        anchor = "center",
        child = prise.Box({
            border = config.borders.style,
            style = { fg = config.borders.focused_color },
            max_width = state.floating.width,
            max_height = state.floating.height,
            child = prise.Terminal({
                pty = tab.floating.pane.pty,
                focus = true,
            }),
        }),
    })
end

function M.view()
    local root = get_active_root()
    if not root then
        return prise.Column({
            cross_axis_align = "stretch",
            children = { prise.Text("Waiting for terminal...") },
        })
    end

    -- Start clock timer for status bar updates
    if config.status_bar.enabled then
        schedule_clock_timer()
    end

    local palette = build_palette()
    local rename = build_rename()
    local rename_tab = build_rename_tab()
    local swap_with_index = build_swap_with_index()
    local session_picker = build_session_picker()
    local layout_picker = build_layout_picker()
    local floating = build_floating()
    local tab_bar = build_tab_bar()
    local tab = get_active_tab()
    local floating_visible = tab and tab.floating and tab.floating.visible
    local overlay_visible = state.palette.visible
        or state.rename.visible
        or state.rename_tab.visible
        or (state.swap_with_index and state.swap_with_index.visible)
        or state.session_picker.visible
        or state.layout_picker.visible
        or floating_visible
    prise.log.debug("view: palette.visible=" .. tostring(state.palette.visible))

    local content
    if not root then
        content = prise.Column({
            cross_axis_align = "stretch",
            children = {},
        })
    elseif state.zoomed_pane_id then
        local path = find_node_path(root, state.zoomed_pane_id)
        if path then
            local pane = path[#path]
            local terminal = prise.Terminal({
                pty = pane.pty,
                focus = not overlay_visible,
            })

            if config.borders.enabled and config.borders.show_single_pane then
                content = prise.Box({
                    border = config.borders.style,
                    style = { fg = config.borders.focused_color },
                    child = terminal,
                })
            else
                content = terminal
            end
        else
            state.zoomed_pane_id = nil
            content = render_node(root, overlay_visible)
        end
    else
        content = render_node(root, overlay_visible)
    end

    local status_bar = config.status_bar.enabled and build_status_bar() or nil

    local main_children = {}
    if tab_bar then
        table.insert(main_children, tab_bar)
    end
    table.insert(main_children, content)
    if status_bar then
        table.insert(main_children, status_bar)
    end

    local main_ui = prise.Column({
        cross_axis_align = "stretch",
        children = main_children,
    })

    -- Build overlay stack: floating pane below modals, modals on top
    local overlay_children = { main_ui }
    if floating then
        table.insert(overlay_children, floating)
    end
    local modal = palette or rename or rename_tab or swap_with_index or session_picker or layout_picker
    if modal then
        table.insert(overlay_children, modal)
        return prise.Stack({
            children = overlay_children,
        })
    end

    if floating then
        return prise.Stack({
            children = overlay_children,
        })
    end

    return main_ui
end

---@param cwd_lookup? fun(pty_id: number): string?
---@return table
function M.get_state(cwd_lookup)
    -- Serialize all tabs
    local tabs_data = {}
    for _, tab in ipairs(state.tabs) do
        table.insert(tabs_data, {
            id = tab.id,
            title = tab.title,
            root = serialize_node(tab.root, cwd_lookup),
            last_focused_id = tab.last_focused_id,
            floating = serialize_floating(tab.floating, cwd_lookup),
        })
    end

    return {
        tabs = tabs_data,
        active_tab = state.active_tab,
        next_tab_id = state.next_tab_id,
        focused_id = state.focused_id,
        next_split_id = state.next_split_id,
        floating_settings = {
            width = state.floating.width,
            height = state.floating.height,
        },
    }
end

---Paint tab-bar metadata (ids, titles, active tab, scroll offset) without any
---pty binding. Used at session-switch derivation time so the tab bar can swap
---old->new in a single frame without going through `deserialize_node` (which
---would drop every tab when the incoming ptys aren't attached yet). A
---follow-up `M.set_state(plan_json, live_lookup)` after `attach_pty` completes
---rebinds live pty refs.
---
---Contract: writes ONLY tab-level metadata. Every tab.root is nil on exit;
---no pane/split structure is created. Does NOT call `deserialize_node`.
---@param saved? table
function M.set_tab_shell(saved)
    -- Clear outgoing session-scoped visual state so the tab bar swap doesn't
    -- bleed palette / zoom / focus from the previous session. Inlined
    -- (branch-local) rather than calling `reset_session_state` because this
    -- branch is based on `main` where that helper does not yet exist; when
    -- merged into arthack-prod the set is a subset of what `reset_session_state`
    -- already clears, so behaviour is consistent.
    state.tabs = {}
    state.active_tab = 1
    state.next_tab_id = 1
    state.focused_id = nil
    state.zoomed_pane_id = nil
    state.pending_command = false
    state.pending_split = nil
    state.pending_new_tab = false
    state.palette.visible = false
    if state.palette.input then
        state.palette.input:clear()
    end
    state.rename.visible = false
    if state.rename.input then
        state.rename.input:clear()
    end
    state.rename_tab.visible = false
    if state.rename_tab.input then
        state.rename_tab.input:clear()
    end
    state.swap_with_index = nil
    state.session_picker.visible = false
    state.layout_picker.visible = false
    state.tab_regions = {}
    state.tab_close_regions = {}
    state.hovered_tab = nil
    state.hovered_close_tab = nil
    -- `state.tab_bar_scroll_offset` is fn-55's field; writing when the key
    -- doesn't pre-exist is harmless in Lua, so always zero it for a clean
    -- viewport on swap. When fn-55 is merged this matches its reset idiom.
    state.tab_bar_scroll_offset = 0

    if not saved then
        prise.request_frame()
        return
    end

    -- Iterate the top-level tabs array; for each tab create a shell with
    -- root = nil. No pty binding, no pane/split structure.
    for _, tab_data in ipairs(saved.tabs or {}) do
        table.insert(state.tabs, {
            id = tab_data.id,
            title = tab_data.title,
            root = nil,
            last_focused_id = tab_data.last_focused_id,
        })
    end

    state.active_tab = saved.active_tab or 1
    -- Restore next_tab_id from JSON (inlined clear above zeroed it to 1);
    -- without this, future tab creation would collide with existing ids.
    state.next_tab_id = saved.next_tab_id or (#state.tabs + 1)

    -- tab_bar_scroll_offset is runtime-only in fn-55 (not in get_state's
    -- serialized shape), so the JSON won't carry it. Read defensively in case
    -- a future fn-55 revision starts persisting it.
    if saved.tab_bar_scroll_offset ~= nil then
        state.tab_bar_scroll_offset = saved.tab_bar_scroll_offset
    end

    -- Clamp active_tab into range (empty-tabs case lands on 1, fine).
    if state.active_tab > #state.tabs then
        state.active_tab = #state.tabs
    end
    if state.active_tab < 1 and #state.tabs > 0 then
        state.active_tab = 1
    end

    prise.request_frame()
end

---@param saved? table
---@param pty_lookup fun(id: number): Pty?
function M.set_state(saved, pty_lookup)
    reset_session_state()

    if not saved then
        return
    end

    -- Build a per-restore table of old-id -> new-id mappings so persisted
    -- focus references (focused_id, last_focused_id) can be translated onto
    -- the remapped id space. Without this, focus would silently fall back to
    -- the first leaf whenever the server reassigned a PTY id on restore.
    local remap = {}

    -- Handle migration from old format (single root) to new format (tabs)
    if saved.tabs == nil and saved.root ~= nil then
        -- Old format: migrate to tabs
        local restored_root = deserialize_node(saved.root, pty_lookup, remap)
        if restored_root then
            local tab_id = 1
            -- Remap focused_id through the old->new table. If the saved focus
            -- referenced a pane that couldn't be restored, fall back to the
            -- first leaf.
            local valid_focus = saved.focused_id and remap[saved.focused_id]
            if not valid_focus then
                local first = get_first_leaf(restored_root)
                valid_focus = first and first.id or nil
            end
            state.tabs = {
                {
                    id = tab_id,
                    root = restored_root,
                    last_focused_id = valid_focus,
                },
            }
            state.active_tab = 1
            state.next_tab_id = tab_id + 1
            state.focused_id = valid_focus
            state.next_split_id = saved.next_split_id or 1
        end
    else
        -- New format: restore tabs
        state.tabs = {}
        for _, tab_data in ipairs(saved.tabs or {}) do
            local restored_root = deserialize_node(tab_data.root, pty_lookup, remap)
            if restored_root then
                -- Remap last_focused_id through the old->new table; fall back
                -- to the first leaf of this tab if the saved focus pane is gone.
                local valid_focus = tab_data.last_focused_id and remap[tab_data.last_focused_id]
                if not valid_focus then
                    local first = get_first_leaf(restored_root)
                    valid_focus = first and first.id or nil
                end
                table.insert(state.tabs, {
                    id = tab_data.id,
                    title = tab_data.title,
                    root = restored_root,
                    last_focused_id = valid_focus,
                    floating = deserialize_floating(tab_data.floating, pty_lookup, remap),
                })
            end
        end
        state.active_tab = saved.active_tab or 1
        state.next_tab_id = saved.next_tab_id or (#state.tabs + 1)
        -- Remap top-level focused_id through the same table. Nil if the saved
        -- pane is gone — the "Ensure focus is valid" block below picks a leaf
        -- from the active tab as a safety net.
        state.focused_id = saved.focused_id and remap[saved.focused_id] or nil
        state.next_split_id = saved.next_split_id or 1

        -- Restore floating pane settings
        if saved.floating_settings then
            state.floating.width = saved.floating_settings.width or state.floating.width
            state.floating.height = saved.floating_settings.height or state.floating.height
        end

        -- Ensure active_tab is valid
        if state.active_tab > #state.tabs then
            state.active_tab = #state.tabs
        end
        if state.active_tab < 1 and #state.tabs > 0 then
            state.active_tab = 1
        end
    end

    -- Ensure focus is valid (focused_id may reference old IDs after PTY remapping)
    if #state.tabs > 0 then
        local tab = state.tabs[state.active_tab]
        if tab and (not state.focused_id or not find_node_path(tab.root, state.focused_id)) then
            local first = get_first_leaf(tab.root)
            if first then
                state.focused_id = first.id
            end
        end
    end

    update_cached_git_branch()
    prise.request_frame()
end

---Return info about the currently active tab.
---@return { index: integer, title: string, pane_count: integer }?
function M.get_active_tab_info()
    local tab = get_active_tab()
    if not tab then
        return nil
    end

    return {
        index = state.active_tab,
        title = get_tab_title(tab, true),
        pane_count = #collect_tab_panes(tab),
    }
end

---Return the 1-based index of the focused pane within the active tab.
---@return integer?
function M.get_focused_pane_index()
    local tab = get_active_tab()
    if not tab or not state.focused_id then
        return nil
    end

    local panes = collect_tab_panes(tab)
    for i, pane in ipairs(panes) do
        if pane.id == state.focused_id then
            return i
        end
    end

    return nil
end

---Return the raw pty_id of the focused pane, or nil when no pane is
---focused. Complements `get_focused_pane_index` for callers that need to
---reference the focused pane by its actual identifier rather than by
---position within a tab — e.g. plugs comparing against pane ids they
---emitted elsewhere.
---@return number?
function M.get_focused_id()
    return state.focused_id
end

---Send a key event to the focused pane's PTY.
---@param data PtyKeyData Key event data: {key, code?, ctrl?, alt?, shift?, super?}
function M.send_key_to_focused(data)
    local pty = get_visible_floating_pty() or get_focused_pty()
    if pty then
        pty:send_key(data)
    end
end

---Send a mouse event to the focused pane's PTY.
---@param data PtyMouseData Mouse event data: {x, y, button, event_type, mods?}
function M.send_mouse_to_focused(data)
    local pty = get_visible_floating_pty() or get_focused_pty()
    if pty then
        pty:send_mouse(data)
    end
end

---Execute a built-in action by name.
---This allows user config code to programmatically trigger actions
---(e.g. from dialog callbacks) without direct access to action_handlers.
---@param name string Action name (e.g. "close_pane", "close_tab")
function M.execute_action(name)
    local handler = action_handlers[name]
    if handler then
        handler()
        prise.request_frame()
    end
end

-- Export internal functions for testing
M._test = {
    is_pane = is_pane,
    is_split = is_split,
    action_handlers = action_handlers,
    collect_panes = collect_panes,
    find_tab_for_pane = find_tab_for_pane,
    collect_tab_panes = collect_tab_panes,
    find_node_path = find_node_path,
    get_first_leaf = get_first_leaf,
    get_last_leaf = get_last_leaf,
    format_palette_item = format_palette_item,
    build_custom_tab_infos = build_custom_tab_infos,
    build_tab_bar_custom = build_tab_bar_custom,
    close_tab = close_tab,
    move_focus = move_focus,
    remove_pane_by_id = remove_pane_by_id,
    set_active_tab_index = set_active_tab_index,
    compute_focus_window = compute_focus_window,
    derive_visible_range = derive_visible_range,
    apply_gutters = apply_gutters,
    clip_boundary_tab = clip_boundary_tab,
    compose_layout_segments = compose_layout_segments,
    derive_click_regions = derive_click_regions,
    build_tab_bar_custom = build_tab_bar_custom,
    validate_tab_bar_layout = validate_tab_bar_layout,
    measure_gutter_slot = measure_gutter_slot,
    -- Test-only setters for the warn-once latch + render callback so tests
    -- can drive the renderer-error posture without relying on test ordering.
    reset_tab_bar_render_warned = function()
        state.tab_bar_render_warned = false
    end,
    set_tab_bar_render = function(cb)
        config.tab_bar.render = cb
    end,
    set_tab_bar_gutters = function(left, right)
        config.tab_bar.gutter_left = left
        config.tab_bar.gutter_right = right
    end,
    set_screen_cols = function(cols)
        state.screen_cols = cols
    end,
    action_handlers = action_handlers,
    set_state = function(test_state)
        state.tabs = test_state.tabs or {}
        state.active_tab = test_state.active_tab or 1
        state.next_tab_id = test_state.next_tab_id or (#state.tabs + 1) -- state.tabs already updated above
        state.focused_id = test_state.focused_id
        state.zoomed_pane_id = test_state.zoomed_pane_id
        state.floating = { width = 0.8, height = 0.8, visible = false, pending = false, resize_mode = false }
        state.hovered_tab = nil
        state.hovered_close_tab = nil
        state.tab_regions = {}
        state.tab_close_regions = {}
        state.tab_bar_render_warned = false
        state.pending_split = nil
        state.next_split_id = test_state.next_split_id or 1
    end,
    -- Returns a direct reference to internal state, not a copy
    get_state = function()
        return state
    end,
    find_tab_by_title = find_tab_by_title,
    move_focus = move_focus,
    set_test_state = function(tabs, active_tab, focused_id)
        state.tabs = tabs
        state.active_tab = active_tab
        state.focused_id = focused_id
    end,
    get_focused_id = function()
        return state.focused_id
    end,
    serialize_node = serialize_node,
}

M._test.build_tab_bar_custom = build_tab_bar_custom
M._test.set_state = function(test_state)
    state.tabs = test_state.tabs or {}
    state.active_tab = test_state.active_tab or 1
    state.next_tab_id = test_state.next_tab_id or (#state.tabs + 1)
    state.focused_id = test_state.focused_id
    state.zoomed_pane_id = test_state.zoomed_pane_id
    state.hovered_tab = nil
    state.hovered_close_tab = nil
    state.tab_regions = {}
    state.tab_close_regions = {}
end
M._test.get_state = function()
    return state
end

return M
