# NAME

prise - architecture and concepts

# DESCRIPTION

Prise is a terminal multiplexer that uses a client-server architecture. The
server manages PTY sessions and persists them across client connections. Clients
connect to render the UI and handle input.

# ARCHITECTURE

## Server

The server runs as a background process, started with **prise serve** or via
a system service. It:

- Creates a Unix domain socket at */tmp/prise-{uid}.sock*
- Manages PTY sessions (spawning shells, handling I/O)
- Persists session state to *~/.local/share/prise/sessions/*
- Sends screen updates to connected clients
- Logs to *~/.cache/prise/server.log*

## Client

Each client connects to the server socket and:

- Renders the terminal UI using the local terminal
- Forwards keyboard and mouse input to the server
- Receives screen updates and repaints

Multiple clients can connect to the same session or pty simultaneously.

# SESSIONS

A **session** is a named collection of tabs and panes that persists across
client connections. Sessions are stored in *~/.local/share/prise/sessions/*.

**prise session list**
:   List all sessions

**prise session attach** [*name*]
:   Attach to a session (default: most recent)

**prise session delete** *name*
:   Delete a session

**prise session rename** *old* *new*
:   Rename a session

# ENVIRONMENT

The following environment variables are set for processes spawned inside prise.
They are used by commands such as **prise tab rename** when they are invoked
from within an existing pane.

**PRISE_PTY**
:   Numeric PTY identifier for the current pane.

**PRISE_PTY_VALIDITY**
:   Server instance identifier used to reject stale tab-rename requests after a
    server restart.

**PRISE_SOCKET**
:   Override path for the prise server socket.

**PRISE_SESSION**
:   Current session name. When set, **prise tab rename** also persists the tab
    title into the session state on disk.

To clear an explicit tab title, run **prise tab rename ""** from inside prise.

Sessions are visible to Lua code (via **prise.list_sessions()**) immediately
upon creation, before the autosave timer writes them to disk.

# SERVICE CONFIGURATION

The server should run continuously in the background. Prise provides service
files for automatic startup.

## macOS (launchd)

Install and enable with:

```
zig build --prefix ~/.local
zig build enable-service --prefix ~/.local
```

This creates a launchd plist at *~/Library/LaunchAgents/sh.prise.server.plist*
that starts the server at login.

To disable:

```
launchctl unload ~/Library/LaunchAgents/sh.prise.server.plist
```

## Linux (systemd)

Install and enable with:

```
zig build --prefix ~/.local
zig build enable-service --prefix ~/.local
```

This creates a systemd user service at
*~/.config/systemd/user/prise.service*.

To disable:

```
systemctl --user disable --now prise.service
```

# UI CONCEPTS

## Panes

A **pane** is a single terminal view backed by a PTY. Panes can be split
horizontally or vertically to create layouts.

## Tabs

A **tab** contains a layout of panes. Switch between tabs without affecting
the running processes.

## Command Mode

Press the leader key (default: **Super+k**) to enter command mode. The status
bar changes color to indicate command mode. Then press a key to execute a
command (e.g., **v** for horizontal split).

## Command Palette

Press **Super+p** to open the command palette. Type to fuzzy-search commands,
then press Enter to execute.

## Session Picker

In command mode (leader key), press **S** to open the session picker. Type to
filter sessions by name, use arrow keys to navigate, and press Enter to switch.

Press **R** in command mode to rename the current session.

# CUSTOM UI

The UI is implemented in Lua and can be customized or replaced entirely. See
**prise**(5) for configuration options.

The **prise** Lua module provides widget primitives:

- **Terminal**: Display a PTY
- **Text**: Static text with styling
- **Row**, **Column**: Layout containers
- **Stack**: Overlay widgets
- **Box**: Border and background
- **Padding**: Add spacing
- **List**: Scrollable list
- **TextInput**: Text input field
- **Positioned**: Absolute positioning

A custom UI must return a table with:

- **update(event)**: Handle input events
- **view()**: Return widget tree to render
- **get_state(cwd_lookup)**: Serialize state for persistence (optional)
- **set_state(saved, pty_lookup)**: Restore state (optional)

Custom UIs may also expose optional helpers used by configuration code:

- **execute_action(name)**: Run a built-in action handler by name
- **setup(opts)**: Apply UI-specific configuration before the UI is returned

The built-in tiling UI's `tab_bar.render` returns a structured layout with
three slots — `{prefix, tabs, suffix}` — so renderers declare fixed left/right
content separately from the windowed tab list. Per-tab entries carry
`label_segments` (label only); core injects a 1-cell separator between each
adjacent pair of visible tabs so separators are never part of a tab's
clippable width. Core applies centered-focus windowing and cell-precise edge
clipping to the `tabs` slot only; `prefix` and `suffix` are never clipped.
Renderers can also emit themed gutter segments via optional `gutter_left` /
`gutter_right` fields on the returned `TabBarLayout` (symmetric,
all-or-nothing); core still decides which side to show based on overflow,
then splices the renderer's segment(s) verbatim. The `tab_bar` config's
plain-string `gutter_left` / `gutter_right` fields drive the fallback when
the renderer emits no gutter fields. See **prise**(5) for the full
`TabBarLayout` definition.

# SEE ALSO

[prise(1)](prise.1.html), [prise(5)](prise.5.html)
