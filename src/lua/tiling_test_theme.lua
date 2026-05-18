---Create a mock Pty object
---@param id integer
---@return Pty
local function mock_pty(id)
    return {
        id = function()
            return id
        end,
        title = function()
            return "mock"
        end,
        cwd = function()
            return nil
        end,
        size = function()
            return { rows = 24, cols = 80, width_px = 0, height_px = 0 }
        end,
        send_key = function() end,
        send_mouse = function() end,
        send_paste = function() end,
        set_focus = function() end,
        close = function() end,
        copy_selection = function() end,
    }
end

-- Mock prise module
package.loaded["prise"] = {
    tiling = function() end,
    Terminal = function(opts)
        return { type = "terminal", pty = opts.pty }
    end,
    Text = function(_)
        return { type = "text" }
    end,
    Column = function(_)
        return { type = "column" }
    end,
    Row = function(_)
        return { type = "row" }
    end,
    Stack = function(_)
        return { type = "stack" }
    end,
    Positioned = function(_)
        return { type = "positioned" }
    end,
    TextInput = function(_)
        return { type = "text_input" }
    end,
    List = function(_)
        return { type = "list" }
    end,
    Box = function(_)
        return { type = "box" }
    end,
    Padding = function(_)
        return { type = "padding" }
    end,
    gwidth = function(s)
        return #s
    end,
    log = { debug = function() end },
    request_frame = function() end,
    save = function() end,
    exit = function() end,
    get_session_name = function()
        return "test"
    end,
}

-- Suppress unused warning: mock_pty is used by the tiling module internally
local _ = mock_pty

local tiling = require("tiling")

-- === get_theme ===

-- Test: get_theme returns default theme without setup
local theme = tiling.get_theme()
assert(theme ~= nil, "get_theme: returns table")
assert(theme.accent == "#89b4fa", "get_theme: default accent")
assert(theme.bg1 == "#1e1e2e", "get_theme: default bg1")
assert(theme.fg_bright == "#cdd6f4", "get_theme: default fg_bright")
assert(theme.green == "#a6e3a1", "get_theme: default green")

-- Test: get_theme returns merged theme after setup with overrides
tiling.setup({ theme = { accent = "#ff0000" } })
theme = tiling.get_theme()
assert(theme.accent == "#ff0000", "get_theme: override applied")
assert(theme.bg1 == "#1e1e2e", "get_theme: defaults preserved after override")
