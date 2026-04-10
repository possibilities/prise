---@meta

---Log functions provided by prise
---@class PriseLog
---@field debug fun(msg: string) Log a debug message
---@field info fun(msg: string) Log an info message
---@field warn fun(msg: string) Log a warning message
---@field err fun(msg: string) Log an error message
---@field error fun(msg: string) Log an error message (alias)

---Spawn options for creating new PTYs
---@class SpawnOptions
---@field cwd? string Working directory for the new process
---@field cmd? string Command to run after shell is ready
---@field argv? string[] Argv for direct exec, bypassing the login shell. Mutually exclusive with cmd.

---The prise module provides core functionality for the terminal multiplexer
---@class prise
---@field log PriseLog Logging functions
---@field platform "macos"|"linux"|"windows"|"unknown" Current platform
---@field keybind KeybindModule Keybind compilation and matching
local prise = {}

---@class PriseUI
---@field update fun(event: table) Handle an input event
---@field view fun(): table Return the widget tree to render
---@field get_state? fun(cwd_lookup: fun(id: number): string?): table Serialize UI state for persistence
---@field set_state? fun(saved: table?, pty_lookup: fun(id: number): Pty?) Restore UI state
---@field setup? fun(opts: table?) Configure the UI (optional)
---@field get_macos_option_as_alt? fun(): boolean Return whether macOS Option should act as Alt
---@field execute_action? fun(name: string) Execute a built-in action by name

---Load the tiling UI module
---@return PriseUI
function prise.tiling() end

---Create a terminal widget that displays a PTY
---@param opts TerminalOpts
---@return table Terminal widget
function prise.Terminal(opts) end

---Create a text widget with optional styling and segments
---@param opts string|TextSegment[]|TextOpts
---@return table Text widget
function prise.Text(opts) end

---Create a column layout that arranges children vertically
---@param opts table[]|LayoutOpts
---@return table Column widget
function prise.Column(opts) end

---Create a row layout that arranges children horizontally
---@param opts table[]|LayoutOpts
---@return table Row widget
function prise.Row(opts) end

---Create a stacked layout that overlays children on top of each other
---@param opts table[]|LayoutOpts
---@return table Stack widget
function prise.Stack(opts) end

---Create a positioned widget that places a child at absolute coordinates
---@param opts PositionedOpts
---@return table Positioned widget
function prise.Positioned(opts) end

---Create a text input widget for capturing user input
---@param opts TextInputOpts
---@return table TextInput widget
function prise.TextInput(opts) end

---Create a list widget with items and optional selection
---@param opts ListOpts|string[]
---@return table List widget
function prise.List(opts) end

---Create a box widget with border and styling options
---@param opts BoxOpts
---@return table Box widget
function prise.Box(opts) end

---Create a padding widget that adds spacing around a child
---@param opts PaddingOpts
---@return table Padding widget
function prise.Padding(opts) end

---Set a timeout to call a function after a delay
---@param ms integer Milliseconds to wait
---@param callback fun() Function to call
---@return Timer
function prise.set_timeout(ms, callback) end

---Exit the application (deletes session)
function prise.exit() end

---Spawn a new PTY process
---@param opts? SpawnOptions
function prise.spawn(opts) end

---Request a frame redraw. The render is scheduled, not synchronous: the
---call returns immediately and the client drains the request on its next
---event-loop tick. Safe to call from inside tiling dispatch handlers and
---other Lua code that runs inside a `ui.update` pcall.
function prise.request_frame() end

---Detach from the current session
---@param session_name? string Optional session name to switch to
function prise.detach(session_name) end

---Get the next available session name
---@return string
function prise.next_session_name() end

---Trigger an auto-save of the session
function prise.save() end

---Get the current session name
---@return string?
function prise.get_session_name() end

---Rename a session
---@param old_name string The current session name
---@param new_name string The new session name
function prise.rename_session(old_name, new_name) end

---Delete a session
---@param session_name string
function prise.delete_session(session_name) end

---List all available sessions
---@return string[]
function prise.list_sessions() end

---Switch to a different session
---@param target_session string The session name to switch to
function prise.switch_session(target_session) end

---Place a PTY in a target session's saved state without switching
---@param session_name string Target session name
---@param pty_id integer PTY ID to place
---@param cwd string Working directory for the PTY
---@param tab_title? string Optional tab title
---@return boolean success
function prise.place_pty_in_session(session_name, pty_id, cwd, tab_title) end

---Create a session
---@param session_name string
---@return boolean success
function prise.create_session(session_name) end

---Create a new TextInput handle
---@return TextInput
function prise.create_text_input() end

---Get the grapheme width of a string (for proper Unicode handling)
---@param str string
---@return integer
function prise.gwidth(str) end

---Slice a string by cell columns, walking grapheme clusters.
---Uses the same `.unicode` width method as `prise.gwidth`.
---A wide grapheme straddling either boundary is dropped and padded with
---a space per covered boundary cell (never emits invalid UTF-8).
---Returns "" when `start_cell < 0`, `end_cell <= start_cell`, or the
---window starts past the string's total cell width.
---@param str string
---@param start_cell integer 0-based first cell to include
---@param end_cell integer 0-based cell past the last included cell
---@return string
function prise.cell_substring(str, start_cell, end_cell) end

---Get the current time formatted as HH:MM
---@return string
function prise.get_time() end

---Get the git branch for a directory
---@param cwd string The directory to check
---@return string? The branch name, or nil if not a git repo
function prise.get_git_branch(cwd) end

return prise
