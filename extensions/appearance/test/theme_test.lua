-- Checks the palette extension without a terminal: what it hands the terminal's
-- set_theme method, what it refuses, and that a palette added at run time is
-- usable. The fake records every block method call, so the assertions are about
-- the exact colors that would be sent.
--
--   luajit extensions/appearance/test/theme_test.lua

local here = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):match("^(.*)/[^/]*$") or "."
local repo = here .. "/../../.."
package.path = repo .. "/test/?.lua;" .. package.path

local Fake = require("fake_rex")
local t = require("helper")
t.extension_dir = here .. "/.."

local fake = Fake.install()
local terminal = "com.superlogical.terminal"

local function fresh(opts)
  fake:reset()
  return t.load_module(opts)
end

local function theme_call()
  return fake:last_call("block")
end

--- Registering the action ----------------------------------------------------

t.section("setup registers one action and touches no terminal")
do
  local M = fresh()
  local action = fake.actions.terminal_theme
  t.check("the action exists under the palette's name", action ~= nil, action)
  t.check("it is categorized for the command palette", action and action.category == "Appearance", action and action.category)
  t.check("it takes an optional theme argument", action and action.args and action.args.theme == "string?",
    action and action.args and action.args.theme)
  t.check("setup alone applies nothing", #fake:calls_of("block") == 0, #fake:calls_of("block"))
  t.check("the default theme is Tokyo Night", M.options.theme == "tokyo-night", M.options.theme)
end

t.section("an option this extension does not have is refused where it is written")
do
  local err = t.error_of(fresh, { background = "#000" })
  t.check("the error names the option", err ~= nil and err:find("unknown appearance option", 1, true) ~= nil, err)
  local bad = t.error_of(fresh, { theme = "no-such-theme" })
  t.check("a theme that does not exist is refused at load",
    bad ~= nil and bad:find("tokyo%-night") ~= nil, bad)
end

--- Applying ------------------------------------------------------------------

t.section("applying a theme is one set_theme call on the focused block")
do
  local M = fresh()
  local result = M.apply({ block_id = "block:1" })
  local call = theme_call()
  t.check("the call goes to the terminal creator", call and call.creator == terminal, call and call.creator)
  t.check("the method is set_theme", call and call.method == "set_theme", call and call.method)
  t.check("it colors the block it was given", call and call.params.block_id == "block:1", call and call.params.block_id)
  t.check("the background is Tokyo Night's", call and call.params.background == "#1a1b26", call and call.params.background)
  t.check("the foreground is Tokyo Night's", call and call.params.foreground == "#c0caf5", call and call.params.foreground)
  t.check("the scheme is dark", call and call.params.scheme == "dark", call and call.params.scheme)
  t.check("all 22 palette slots are sent", call and #call.params.palette == 22, call and #call.params.palette)
  t.check("slot 0 is the palette's first entry", call and call.params.palette[1] == "0=#15161e",
    call and call.params.palette[1])
  t.check("the result names the theme and the block",
    result.theme == "tokyo-night" and result.block_id == "block:1", result and (result.theme or ""))
end

t.section("which block, and which theme")
do
  local M = fresh()
  local err = t.error_of(M.apply, nil)
  t.check("a caller with no terminal is refused", err ~= nil and err:find("terminal", 1, true) ~= nil, err)

  M.apply({ block_id = "block:7" }, "tokyo-night")
  t.check("a theme named in the call wins over the default",
    theme_call().params.block_id == "block:7", theme_call().params.block_id)

  local unknown = t.error_of(M.apply, { block_id = "block:1" }, "dracula")
  t.check("an unknown theme lists the ones that exist",
    unknown ~= nil and unknown:find("dracula", 1, true) ~= nil and unknown:find("tokyo%-night") ~= nil, unknown)
end

--- Adding a palette ---------------------------------------------------------

t.section("a palette added at run time is a first-class theme")
do
  local M = fresh()
  M.register{
    name = "paper",
    foreground = "#111",
    background = "#fff",
    cursor = "#111",
    scheme = "light",
    palette = { "0=#000", "1=#900" },
  }
  M.apply({ block_id = "block:1" }, "paper")
  local call = theme_call()
  t.check("the background is the one registered", call.params.background == "#fff", call.params.background)
  t.check("a short palette is sent as it is", #call.params.palette == 2, #call.params.palette)

  local nameless = t.error_of(M.register, { background = "#000" })
  t.check("a theme without a name is refused", nameless ~= nil and nameless:find("name", 1, true) ~= nil, nameless)
end

t.done()
