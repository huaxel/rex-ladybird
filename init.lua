-- rex-extensions: the collection, loaded in one line.
--
--   require("rex-extensions").setup{}
--
-- Every extension it loads is a plain Rex module in extensions/<name>/init.lua,
-- so each one also works on its own with require("<name>"): this file is a
-- convenience, not a framework. What it adds is package.path entries for a
-- checkout that the installer has not linked, and one place to list what the
-- collection contains.

local HOME = os.getenv("HOME")
local MODULE_DIR = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):match("^(.*)/[^/]*$")
  or (HOME .. "/.config/rex/rex-extensions")

-- Extensions that provide a module. A directory in extensions/ with an
-- init.lua belongs here; test/manifest_check.py fails when the two drift.
-- Order matters only when one extension calls another's action at load time.
local MODULES = { "appearance", "rex-ladybird", "tui-launcher" }

-- Require from a checkout, before the installer's symlinks are consulted, so
-- `rex do` on a script in this repository works with nothing installed.
package.path = MODULE_DIR .. "/extensions/?.lua;"
  .. MODULE_DIR .. "/extensions/?/init.lua;"
  .. package.path

local M = {
  options = {
    -- nil loads every extension in MODULES; a list loads only those.
    extensions = nil,
    -- Per-extension tables, passed to that extension's setup as its options:
    --   options = { ["rex-ladybird"] = { hide_status_line = false } }
    options = {},
  },
  loaded = {},
}

local function raise(message)
  error(message, 0)
end

local function known(name)
  for _, candidate in ipairs(MODULES) do
    if candidate == name then return true end
  end
  return false
end

-- `require` fails the same way whether the extension is missing or broken. Only
-- the first is ordinary, when the collection was installed partially, so the
-- match is on *this* module's name: an extension that is present but whose own
-- dependency is missing says "module 'dep' not found" and must be reported, not
-- skipped. Skipping it would hide a broken install behind a working one.
local function missing(error_message, name)
  return type(error_message) == "string"
    and error_message:find("module '" .. name .. "' not found", 1, true) ~= nil
end

local function load(name, settings)
  local ok, module = pcall(require, name)
  if not ok then return nil, module end
  if type(module) == "table" and type(module.setup) == "function" then
    local configured, err = pcall(module.setup, settings or {})
    if not configured then return nil, err end
  end
  return module
end

function M.setup(opts)
  opts = opts or {}
  for name in pairs(opts) do
    if name ~= "extensions" and name ~= "options" then
      raise("unknown rex-extensions option: " .. tostring(name))
    end
  end
  if opts.extensions ~= nil then M.options.extensions = opts.extensions end
  if opts.options ~= nil then M.options.options = opts.options end

  local wanted = M.options.extensions or MODULES
  local explicit = M.options.extensions ~= nil
  for _, name in ipairs(wanted) do
    if not known(name) then
      raise("no such rex extension: " .. tostring(name) .. " (this collection has "
        .. table.concat(MODULES, ", ") .. ")")
    end
  end

  local loaded, skipped = {}, {}
  for _, name in ipairs(wanted) do
    if M.loaded[name] then
      loaded[#loaded + 1] = name   -- loaded by an earlier setup call
    else
      local module, err = load(name, M.options.options[name])
      if module == nil then
        if not missing(err, name) then raise(err) end
        if explicit then
          raise("rex extension not installed: " .. name
            .. " (link it with ./install.sh " .. name .. ")")
        end
        skipped[#skipped + 1] = name
      else
        M.loaded[name] = module
        loaded[#loaded + 1] = name
      end
    end
  end
  -- `loaded` is what actually loaded: a name that was asked for and skipped is
  -- in `skipped`, not here, or a partial install looks complete.
  return { loaded = loaded, skipped = skipped }
end

return M
