-- Appearance: terminal palettes applied through the terminal's own set_theme
-- block method. Nothing is written to a config file and nothing restarts: the
-- colors change in the panes you already have, and a theme you add here is one
-- table entry.
--
--   require("appearance").setup{ theme = "tokyo-night" }
--   rex.bind("ctrl+b>y", "terminal_theme")
--
-- This is the smallest extension in the collection: one action, one block
-- method, no picker required, and a test that never touches a terminal.

local TERMINAL_CREATOR = "com.superlogical.terminal"

-- The 22 colors are the terminal's palette slots: 0-7 the normal colors, 8-15
-- their bright forms, and 16-21 whatever the program asks for beyond those.
local TOKYO_NIGHT = {
  name = "tokyo-night",
  title = "Tokyo Night",
  scheme = "dark",
  foreground = "#c0caf5",
  background = "#1a1b26",
  cursor = "#c0caf5",
  palette = {
    "0=#15161e", "1=#f7768e", "2=#9ece6a", "3=#e0af68",
    "4=#7aa2f7", "5=#bb9af7", "6=#7dcfff", "7=#a9b1d6",
    "8=#414868", "9=#f7768e", "10=#9ece6a", "11=#e0af68",
    "12=#7aa2f7", "13=#bb9af7", "14=#7dcfff", "15=#c0caf5",
    "16=#ff9e64", "17=#db4b4b",
    "18=#1f2335", "19=#292e42", "20=#3b4261", "21=#565f89",
  },
}

local M = {
  options = {
    -- The theme the action applies when it is not given one.
    theme = "tokyo-night",
  },
  themes = { [TOKYO_NIGHT.name] = TOKYO_NIGHT },
}

local function raise(message)
  error(message, 0)
end

local function theme_names()
  local names = {}
  for name in pairs(M.themes) do names[#names + 1] = name end
  table.sort(names)
  return table.concat(names, ", ")
end

function M.theme(name)
  local theme = M.themes[name or M.options.theme]
  if theme == nil then
    raise("no such terminal theme: " .. tostring(name or M.options.theme)
      .. " (this collection has " .. theme_names() .. ")")
  end
  return theme
end

-- Add a palette without editing this file: M.register{ name = "mine", ... }
-- with the same fields, then rex do terminal_theme theme=mine.
function M.register(theme)
  if type(theme) ~= "table" or type(theme.name) ~= "string" or theme.name == "" then
    raise("a theme needs a name")
  end
  M.themes[theme.name] = theme
  return theme
end

-- set_theme applies at once when the caller owns the block or no client does,
-- and otherwise when the caller becomes the owner; a terminal that refuses says
-- so in the second return value.
function M.apply(ctx, name)
  local theme = M.theme(name)
  if ctx == nil or ctx.block_id == nil then
    raise("apply a theme from the terminal it should color, not from a client")
  end
  local result, err = rex.block.call(TERMINAL_CREATOR, "set_theme", {
    block_id = ctx.block_id,
    foreground = theme.foreground,
    background = theme.background,
    cursor = theme.cursor,
    scheme = theme.scheme,
    palette = theme.palette,
  })
  if result == nil then raise(err or ("could not apply " .. theme.name)) end
  return { theme = theme.name, block_id = ctx.block_id }
end

function M.setup(opts)
  for name, value in pairs(opts or {}) do
    if M.options[name] == nil then raise("unknown appearance option: " .. tostring(name)) end
    M.options[name] = value
  end
  -- Fail where the mistake is: at load, not the first time the key is pressed.
  M.theme(M.options.theme)

  rex.action{
    name = "terminal_theme",
    title = "Appearance: apply a terminal theme…",
    description = "Color this terminal block with one of the palettes this collection ships.",
    category = "Appearance",
    keywords = "theme colors palette tokyo night dark appearance",
    args = { theme = "string?" },
    run = function(ctx, args) return M.apply(ctx, args and args.theme) end,
  }
  return M
end

return M
