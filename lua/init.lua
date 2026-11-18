-- rexweb: native WebKit browser panes for Rex.
--
-- Add this to ~/.config/rex/init.lua:
--
--   require("rexweb").setup{}
--
-- Options, with their defaults:
--
--   require("rexweb").setup{
--     key = "shift+cmd+b",   -- open a browser pane; false for no shortcut
--     split = "right",       -- right, left, above, or below
--     ratio = 0.5,           -- the share of the split the browser pane gets
--     home = "",             -- the page a new pane opens; empty focuses the address bar
--   }

local M = {}

local SHELL = "com.superlogical.terminal.shell"
local APP = os.getenv("HOME") .. "/Applications/RexWeb.app"
local PANE = APP .. "/Contents/Resources/rexweb-pane"

local defaults = {
  key = "shift+cmd+b",
  split = "right",
  ratio = 0.5,
  home = "",
}

local placement = {
  right = { direction = "horizontal", side = "after" },
  left = { direction = "horizontal", side = "before" },
  below = { direction = "vertical", side = "after" },
  above = { direction = "vertical", side = "before" },
}

local function pane_block(url)
  return rex.layout.block{
    flavor = SHELL,
    label = "browser",
    options = { command = { "env", "REXWEB_FOCUS=true", PANE, url or "" } },
  }
end

function M.setup(opts)
  opts = opts or {}
  for k, v in pairs(defaults) do
    if opts[k] == nil then opts[k] = v end
  end
  local where = placement[opts.split]
  if where == nil then
    error("rexweb: split must be right, left, above, or below, not " .. tostring(opts.split), 0)
  end

  rex.action{
    name = "rexweb_open",
    title = "Open Browser Pane",
    description = "Open a WebKit browser pane beside this pane.",
    category = "Browser",
    keywords = "browser web webkit safari url page preview localhost",
    args = { url = "string?" },
    run = function(ctx, args)
      local split, err = rex.session.new_split{
        anchor_id = ctx.block_id,
        direction = where.direction,
        side = where.side,
        ratio = where.side == "after" and (1 - opts.ratio) or opts.ratio,
        focus = true,
        layout = pane_block(args.url or opts.home),
      }
      if err ~= nil then error(err, 0) end
      return split
    end,
  }

  rex.action{
    name = "rexweb_open_tab",
    title = "Open Browser Tab",
    description = "Open a WebKit browser pane in a new tab.",
    category = "Browser",
    keywords = "browser web webkit safari url page tab window",
    args = { url = "string?" },
    run = function(ctx, args)
      local w, err = rex.session.new_window{ layout = pane_block(args.url or opts.home) }
      if err ~= nil then error(err, 0) end
      return w
    end,
  }

  if opts.key then
    rex.bind(opts.key, "rexweb_open")
  end
end

return M
