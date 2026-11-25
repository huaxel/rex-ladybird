-- Shared by the Lua tests: a check function that counts failures, and a fresh
-- copy of the module for each test.
--
--   local t = require("helper")
--   t.section("what is being tested")
--   t.check("what should hold", condition, optional_detail)
--   t.done()   -- exits 1 if any check failed

local helper = {}

local test_dir = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):match("^(.*)/[^/]*$") or "."
if test_dir:sub(1, 1) ~= "/" then test_dir = (os.getenv("PWD") or ".") .. "/" .. test_dir end
helper.root = test_dir:match("^(.*)/test$") or (test_dir .. "/..")

local failed = 0

function helper.section(name)
  print("\n" .. name)
end

function helper.check(name, condition, detail)
  if condition then
    print("  ok   " .. name)
  else
    print("  FAIL " .. name .. (detail ~= nil and ("\n       " .. tostring(detail)) or ""))
    failed = failed + 1
  end
end

-- A fresh copy of the module, with options that keep it inside the fake's
-- temporary directory.
function helper.load_module(fake, opts)
  local merged = {
    binary = "/tmp/Ladybird.app/Contents/MacOS/Ladybird",
    ladyctl = "/tmp/ladyctl",
    chrome_history = fake.tmp .. "/chrome/History",
    profile = fake.tmp .. "/profile",
  }
  for name, value in pairs(opts or {}) do merged[name] = value end
  -- The module checks that the binary is executable before it opens a pane, so
  -- the stand-in path has to pass that probe too.
  fake:on_exec("/bin/test -x " .. merged.binary, { ok = true, stdout = "" })
  local M = dofile(helper.root .. "/init.lua")
  return M.setup(merged), M
end

-- The error a function raises, or nil if it returns.
function helper.error_of(fn, ...)
  local ok, err = pcall(fn, ...)
  if ok then return nil end
  return tostring(err)
end

-- Read a file the module wrote, or nil.
function helper.read_file(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local content = file:read("*a")
  file:close()
  return content
end

function helper.done()
  if failed > 0 then
    print("\n" .. failed .. " check(s) failed")
    os.exit(1)
  end
  print("\nall checks passed")
end

return helper
