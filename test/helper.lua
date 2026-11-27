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
-- The repository's test directory, so helper.root is the checkout.
helper.root = test_dir:match("^(.*)/test$") or (test_dir .. "/..")
-- The extension under test. This file lives in the repository's test
-- directory, not beside the test that requires it, so it cannot work out whose
-- module to load: every test sets this to its own directory first.
helper.extension_dir = nil

local function module_path()
  local dir = helper.extension_dir
  if type(dir) ~= "string" then
    error("set helper.extension_dir to the extension's directory before loading a module", 0)
  end
  return dir .. "/init.lua"
end

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

-- A fresh copy of the module under test, set up with `opts`. The file is read
-- again for each call, so a test that changes HOME or the filesystem gets the
-- defaults a fresh Rex would compute.
function helper.load_module(opts)
  local M = dofile(module_path())
  return M.setup(opts or {}), M
end

-- The module under test without setup, for the cases setup itself is what is
-- being checked.
function helper.read_module()
  return dofile(module_path())
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
