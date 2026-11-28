-- Checks the collection's own module: that require("rex-extensions") finds the
-- extensions in a bare checkout, that a subset install loads only what was
-- asked for, and that a name or option that does not exist is refused where it
-- is written rather than failing later inside an extension.
--
--   luajit test/collection_test.lua

local here = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local Fake = require("fake_rex")
local t = require("helper")
local repo = here .. "/.."

local fake = Fake.install()

local function collection()
  fake:reset()
  return dofile(repo .. "/init.lua")
end

local function action_names()
  local names = {}
  for name in pairs(fake.actions) do names[#names + 1] = name end
  table.sort(names)
  return names
end

t.section("one line loads the whole collection")
do
  local C = collection()
  local result = C.setup{}
  t.check("no extension is skipped in a full checkout", #result.skipped == 0, table.concat(result.skipped, ", "))
  t.check("every extension reports as loaded", #result.loaded == 3, #result.loaded)
  local names = table.concat(action_names(), " ")
  t.check("the palette extension registered its action", names:find("terminal_theme", 1, true) ~= nil, names)
  t.check("the browser extension registered all eight", (function()
    local count = 0
    for _, name in ipairs(action_names()) do
      if name:sub(1, 9) == "ladybird_" then count = count + 1 end
    end
    return count == 8
  end)(), names)
  t.check("the launcher registered its action", names:find("tui_launcher", 1, true) ~= nil, names)
end

t.section("a partial install loads only what it names")
do
  local C = collection()
  local result = C.setup{ extensions = { "appearance" } }
  t.check("one extension loaded", #result.loaded == 1 and result.loaded[1] == "appearance", result.loaded[1])
  t.check("and nothing else registered an action", table.concat(action_names(), " ") == "terminal_theme",
    table.concat(action_names(), " "))
end

t.section("per-extension options reach that extension")
do
  local C = collection()
  C.setup{ options = { appearance = { theme = "tokyo-night" } } }
  local module = C.loaded.appearance
  t.check("the option was applied", module.options.theme == "tokyo-night", module.options.theme)
end

t.section("a name or option this collection does not have is refused")
do
  local C = collection()
  local err = t.error_of(C.setup, { extensions = { "ladybird" } })
  t.check("the refusal names the ones that exist",
    err ~= nil and err:find("ladybird", 1, true) ~= nil and err:find("rex%-ladybird") ~= nil, err)

  local other = collection()
  err = t.error_of(other.setup, { extension = { "appearance" } })
  t.check("a misspelled top-level option is refused",
    err ~= nil and err:find("unknown rex-extensions option", 1, true) ~= nil, err)

  local third = collection()
  err = t.error_of(third.setup, { options = { appearance = { background = "#000" } } })
  t.check("an option an extension does not have is refused by that extension",
    err ~= nil and err:find("unknown appearance option", 1, true) ~= nil, err)
end

t.section("setup twice does not register anything twice")
do
  local C = collection()
  C.setup{}
  local first = table.concat(action_names(), " ")
  C.setup{}
  t.check("the action list is unchanged", table.concat(action_names(), " ") == first, table.concat(action_names(), " "))
end


--- Missing and broken ------------------------------------------------

t.section("a partially installed collection skips what is absent, loudly nowhere else")
do
  -- A collection whose list names two extensions: one that is not there, and
  -- one that is there but needs a module nobody has. The first is ordinary when
  -- the installer linked a subset; the second is a broken install and must
  -- raise, or a quarter of the collection silently stops existing.
  local function fixture(list, files)
    local dir = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/rex-ext-fixture." .. tostring(os.time())
      .. tostring(math.random(1000, 9999))
    os.execute("mkdir -p '" .. dir .. "/extensions'")
    for name, body in pairs(files or {}) do
      os.execute("mkdir -p '" .. dir .. "/extensions/" .. name .. "'")
      local file = assert(io.open(dir .. "/extensions/" .. name .. "/init.lua", "w"))
      file:write(body)
      file:close()
    end
    local source = io.open(repo .. "/init.lua", "r")
    local body = source:read("*a")
    source:close()
    local rewritten = body:gsub("local MODULES = {[^}]*}", "local MODULES = { " .. list .. " }", 1)
    local out = assert(io.open(dir .. "/init.lua", "w"))
    out:write(rewritten)
    out:close()
    return dir
  end

  local absent = "no-such-extension-anywhere"
  local dir = fixture('"' .. absent .. '"', {})
  local C = dofile(dir .. "/init.lua")
  local result = C.setup{}
  t.check("an absent extension is skipped, not fatal", #result.skipped == 1 and result.skipped[1] == absent,
    table.concat(result.skipped, ", "))
  t.check("and it is not reported as loaded", #result.loaded == 0, #result.loaded)

  local broken_dir = fixture('"broken"', {
    broken = 'local dep = require("missing-dependency")\nreturn { setup = function() end }\n',
  })
  local Broken = dofile(broken_dir .. "/init.lua")
  local raised = t.error_of(Broken.setup, {})
  t.check("an extension whose dependency is missing raises", raised ~= nil, raised)
  t.check("and the message names the missing dependency",
    raised ~= nil and raised:find("missing%-dependency") ~= nil, raised)

  local named = t.error_of(C.setup, { extensions = { absent } })
  t.check("naming an uninstalled extension says how to install it",
    named ~= nil and named:find("not installed", 1, true) ~= nil and named:find("install.sh", 1, true) ~= nil,
    named)

  os.execute("rm -rf '" .. dir .. "' '" .. broken_dir .. "'")
end

t.done()
