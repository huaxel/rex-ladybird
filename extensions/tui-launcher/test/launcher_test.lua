-- Tests the index without touching your real history: builds a fixture history
-- database, points the launcher at it, and checks what the picker would show.
--
--   TUI_LAUNCHER_DB=/tmp/atuin-fixture.db rex do extensions/tui-launcher/test/launcher_test.lua
--
-- Every case is a program whose runs are shaped like something real: a TUI that
-- sits for minutes, a one-shot that returns at once, a build that is long but
-- never a tool, and a TUI that has not been used for a year.

local db = os.getenv("TUI_LAUNCHER_DB")
if not db then
  print("set TUI_LAUNCHER_DB to a scratch path first, for example /tmp/atuin-fixture.db")
  os.exit(2)
end

-- The clock is read here, not pinned: the ages below are what the cases are
-- about, so a fixture with a fixed date would quietly stop testing "today" the
-- day after it was written.
local NOW = os.time()
local DAY = 86400                 -- the age column below counts days, so 3 means three days

local function ns(seconds) return string.format("%d", seconds * 1000000000) end

-- {command, seconds-ago, duration-in-seconds, times}
local RUNS = {
  -- a TUI: 10 runs, most of them minutes long, last one today
  { "top -o cpu", 0, 300, 7 },
  { "top", 1, 120, 3 },
  -- an editor TUI used four times
  { "vi notes.md", 3, 45, 2 },
  { "vi", 4, 30, 2 },
  -- a build: longest runs of all, but never something to launch
  { "make clean build", 0, 900, 6 },
  -- a one-shot command run constantly
  { "cd ..", 0, 0, 30 },
  { "git status", 0, 1, 20 },
  -- long, but only twice: below MIN_RUNS
  { "tput reset", 1, 5, 2 },
  -- a TUI that fell out of use
  { "sysctl -a", 400, 60, 6 },
  -- a tool whose argument names a target: each target deserves its own row
  { "ssh alpha", 0, 600, 5 },
  { "ssh beta", 1, 600, 3 },
  -- skipped on purpose: it does not resolve to a program
  { "no-such-tool-anywhere", 0, 500, 5 },
}

local function sql_quote(text) return "'" .. text:gsub("'", "''") .. "'" end

local rows = {}
local id = 0
for _, run in ipairs(RUNS) do
  local command, age_days, duration, times = run[1], run[2], run[3], run[4]
  for index = 1, times do
    id = id + 1
    local when_ = NOW - age_days * DAY - index * 60
    rows[#rows + 1] = string.format(
      "insert into history (id, command, timestamp, duration, exit, cwd, session) values ('%d', %s, %s, %s, 0, '/tmp', 'fixture')",
      id, sql_quote(command), ns(when_), ns(duration))
  end
end

local sqlite = "/usr/bin/sqlite3"
local fixture = table.concat({
  "drop table if exists history;",
  "create table history (id text primary key, command text not null, timestamp integer not null,",
  "  duration integer not null, exit integer not null, cwd text not null, session text not null,",
  "  deleted_at integer);",
  table.concat(rows, ";\n") .. ";",
}, "\n")

os.remove(db)   -- harmless when the fixture is not there yet
local result = rex.exec({ sqlite, db, fixture })
if not result or not result.ok then
  print("could not build the fixture: " .. tostring(result and result.stderr))
  os.exit(2)
end

-- Load the plugin by path: a script's require looks next to the script, not
-- in the config directory the way init.lua's require does.
local here = (debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)/[^/]*$")
dofile(here .. "/../init.lua")
local index = rex.invoke("tui_launcher", { dry = true })

local failures = 0
local function check(name, actual, expected)
  if actual == expected then
    print(string.format("ok   %s", name))
  else
    failures = failures + 1
    print(string.format("FAIL %s\n       expected: %s\n       actual:   %s",
      name, tostring(expected), tostring(actual)))
  end
end

local titles, by_title, tool_titles, action_items, ids = {}, {}, {}, {}, {}
for _, item in ipairs(index.items or {}) do
  titles[#titles + 1] = item.title
  by_title[item.title] = item
  ids[item.id] = (ids[item.id] or 0) + 1
  local kind = item.id:match("^(%a+):") or "tool"
  if kind == "tool" then
    tool_titles[#tool_titles + 1] = item.title
  elseif kind == "rex" then
    action_items[#action_items + 1] = item
  end
end

check("the index holds the TUIs that qualify", table.concat(tool_titles, ","), "top,ssh,vi")
check("tools come first", titles[1] ~= nil and not titles[1]:find("^%a+:") and by_title[titles[1]].detail ~= "action", true)
check("every id is unique", (function()
  for id, count in pairs(ids) do if count > 1 then return id .. " appears " .. count .. " times" end end
  return true
end)(), true)
check("a TUI's usual line is the most repeated one", by_title.top and by_title.top.subtitle,
  "usual: top -o cpu")
check("run counts are summed across its lines", by_title.top and by_title.top.detail,
  "10×  today")
check("a build is never offered", by_title.make, nil)
check("a one-shot command is never offered", by_title.cd or by_title.git, nil)
check("a program under MIN_RUNS is left out", by_title.tput, nil)
check("a program unused for a year is left out", by_title.sysctl, nil)
check("a program that does not resolve is left out", by_title["no-such-tool-anywhere"], nil)
check("every item carries an id, icon and detail",
  titles[1] ~= nil and by_title[titles[1]].id ~= nil
    and by_title[titles[1]].icon ~= nil and by_title[titles[1]].detail ~= nil, true)

local ids_seen = {}
for _, item in ipairs(index.items or {}) do ids_seen[item.id] = item end
check("a named target gets its own row", ids_seen["line:ssh beta"] ~= nil, true)
check("the target row shows the whole line", ids_seen["line:ssh beta"]
  and ids_seen["line:ssh beta"].subtitle, "ssh · usual")
check("the most used target stays the tool's own row", by_title.ssh
  and by_title.ssh.subtitle, "usual: ssh alpha")

local function route(text)
  local result, problem = rex.invoke("tui_launcher", { command = text, dry = true })
  if not result then return tostring(problem) end
  return result.route, result.target
end
check("a URL routes to the opener", route("https://example.com/x"), "url")
check("a folder routes to a tab there", route("/tmp"), "folder")
check("a file routes to its folder", select(2, route("/etc/hosts")), "/etc")
check("~ expands", select(2, route("~/dotfiles")), (os.getenv("HOME") or "") .. "/dotfiles")
check("anything else is a command", route("echo hi"), "command")

local kinds = {}
for _, item in ipairs(index.items or {}) do
  kinds[item.detail] = (kinds[item.detail] or 0) + 1
end
check("the live server's sessions are listed", (kinds.session or 0) >= 1, true)
check("the Applications folders are listed", (kinds.app or 0) >= 1, true)
check("tools keep their run counts as the detail", by_title.top and by_title.top.detail,
  "10×  today")
check("an unknown app is refused",
  tostring(select(2, rex.invoke("tui_launcher", { command = "app:NoSuchApp" }))):find("no app named", 1, true) ~= nil,
  true)

-- Dispatch: a Rex action row runs that action, and an unknown name is an error.
local ran = nil
rex.action{ name = "probe_action", title = "Probe", run = function() ran = true return "ok" end }
local dispatched = rex.invoke("tui_launcher", { command = "rex:probe_action" })
check("picking a Rex action runs it", ran, true)
check("the result names the action", dispatched and dispatched.action, "probe_action")
local unknown_result, unknown_err = rex.invoke("tui_launcher", { command = "rex:no_such_action" })
check("an unknown Rex action does not run", unknown_result, nil)
check("the refusal names it", tostring(unknown_err):find("no_such_action", 1, true) ~= nil, true)

os.remove(db)
print(string.format("\n%d check(s) failed", failures))
os.exit(failures == 0 and 0 or 1)
