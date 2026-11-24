-- Exercises the parts of init.lua that can be checked without a browser: the
-- command channel, the tab registry, port allocation and the pickers.
--
--   luajit test/module_test.lua

local here = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local Fake = require("fake_rex")
local t = require("helper")

local fake = Fake.install()
local terminal = "com.superlogical.terminal"

local function state_dir() return fake.env.XDG_STATE_HOME .. "/rex-ladybird" end
local function tabs_file() return state_dir() .. "/tabs" end

-- A module with a Ladybird pane already in a window, plus the block a split
-- would create.
local function fresh(opts)
  fake:reset()
  os.execute("rm -rf '" .. state_dir() .. "'")
  local M = t.load_module(fake, opts)
  local session = fake:add_session()
  fake:add_block(session, "block:1", "Ladybird")
  fake:add_block(session, "block:2", "Ladybird")
  fake:set_process("block:1", "/tmp/Ladybird.app/Contents/MacOS/Ladybird")
  fake:set_process("block:2", "/tmp/Ladybird.app/Contents/MacOS/Ladybird")
  fake.split_result = { block_id = "block:2" }
  return M, session
end

local function write_tabs(lines)
  os.execute("mkdir -p '" .. state_dir() .. "'")
  local file = assert(io.open(tabs_file(), "w"))
  file:write(table.concat(lines, "\n"), "\n")
  file:close()
end

local function last_write()
  local call = fake:last_call("block")
  return call.params.data, call.params.block_id
end

--- The command channel ------------------------------------------------------

t.section("navigation uses the browser's own command channel")
do
  local M = fresh()

  M.open({ block_id = "block:1" }, "https://example.com/a?b=1")
  local data, block_id = last_write()
  t.check("open is one APC command", data == "\27_ladybird;open;https://example.com/a?b=1\27\\", data)
  t.check("it goes to the pane it was asked about", block_id == "block:1", block_id)

  local err = t.error_of(M.open, { block_id = "block:1" }, "https://example.com/\27]0;title\7")
  t.check("a URL carrying an escape is refused", err and err:find("escape", 1, true) ~= nil, err)

  M.open({ block_id = "block:1" }, "https://example.com/\r\nnext")
  data = last_write()
  t.check("line breaks are stripped, not sent", data == "\27_ladybird;open;https://example.com/next\27\\", data)
end

t.section("the pane is identified by what it runs, not by its status line")
do
  local M = fresh()
  -- A status line that looks like Ladybird must not make a shell a target.
  fake:set_status("block:1", "● Something — https://example.com/   ctrl-l url · ctrl-r reload")
  fake:set_process("block:1", "/bin/zsh")
  local other = fake:add_session()
  fake:add_block(other, "block:9", "Ladybird")
  fake:set_process("block:9", "/opt/Ladybird/Build/release/bin/Ladybird.app/Contents/MacOS/Ladybird")
  fake:set_process("block:2", "/bin/zsh")

  M.open({ block_id = "block:1" }, "https://example.com/")
  local _, block_id = last_write()
  t.check("a shell labelled like Ladybird is skipped", block_id == "block:9", block_id)
end

--- Launching ------------------------------------------------------------

t.section("a new pane is launched headless on the shared profile")
do
  local M = fresh()
  fake.split_result = { block_id = "block:2" }
  M.launch({ block_id = "block:1" }, "https://example.com/")
  local split = fake:last_call("split")
  local command = split.spec.layout.options.command
  local joined = table.concat(command, " ")
  t.check("terminal mode", joined:find("--headless=terminal", 1, true) ~= nil, joined)
  t.check("shared profile", joined:find("--profile-path=" .. fake.tmp .. "/profile", 1, true) ~= nil, joined)
  t.check("devtools port", joined:find("--devtools=9317", 1, true) ~= nil, joined)
  t.check("the address is the last argument", command[#command] == "https://example.com/", command[#command])
  t.check("the pane is labelled for later lookup", split.spec.layout.label == "Ladybird", split.spec.layout.label)

  local data, block_id = last_write()
  t.check("the status line is hidden when configured", data == "\27_ladybird;chrome;off\27\\" and block_id == "block:2",
    tostring(data) .. " to " .. tostring(block_id))
end

t.section("hiding the status line is optional")
do
  local M = fresh({ hide_status_line = false })
  M.launch({ block_id = "block:1" }, "https://example.com/")
  local writes = fake:calls_of("block")
  local sent = 0
  for _, call in ipairs(writes) do
    if call.params.data and call.params.data:find("ladybird;chrome", 1, true) then sent = sent + 1 end
  end
  t.check("nothing is sent when the option is off", sent == 0, sent)
end

--- Tabs ----------------------------------------------------------------

t.section("a tab is a block with its own devtools port")
do
  local M = fresh()
  local result = M.tab_new({ block_id = "block:1" }, "https://example.com/one")
  t.check("the tab opened", result.opened == true and result.block_id == "block:2", result.block_id)
  t.check("the first free port is used", result.port == 9317, result.port)
  t.check("the registry records block, port and url",
    t.read_file(tabs_file()) == "block:2\t9317\thttps://example.com/one\n", t.read_file(tabs_file()))

  local zoom = fake:last_call("call")
  t.check("showing a tab zooms its block", zoom.method == "session.zoom_block" and zoom.params.zoom == true,
    zoom.method)

  M.tab_new({ block_id = "block:1" }, "https://example.com/two")
  local second = fake:last_call("call")
  t.check("showing the new tab also zooms", second.method == "session.zoom_block", second.method)
end

t.section("ports already in use are skipped")
do
  local M = fresh()
  -- block:2 is live, so its port is still held; 9318 has something listening.
  write_tabs({ "block:2\t9317\thttps://recorded.example/" })
  fake.busy_ports[9318] = true
  local result = M.tab_new({ block_id = "block:1" }, "https://example.com/")
  t.check("a recorded port is not reused", result.port ~= 9317, result.port)
  t.check("a port something is listening on is not reused", result.port == 9319, result.port)
  local lines = t.read_file(tabs_file())
  t.check("the registry keeps the earlier tab", lines:find("block:2\t9317", 1, true) ~= nil, lines)
end

t.section("switching and closing tabs")
do
  local M = fresh()
  write_tabs({ "block:1\t9317\thttps://a.example/", "block:2\t9318\thttps://b.example/" })

  fake.pick_answers = { { value = "block:2" } }
  local switched = M.tabs({ block_id = "block:1" })
  t.check("the picked tab is reported", switched.switched == true and switched.block_id == "block:2", switched.block_id)
  local zoom = fake:last_call("call")
  t.check("and zoomed", zoom.method == "session.zoom_block" and zoom.params.block_id == "block:2", zoom.method)

  fake.pick_answers = { { value = "block:2" } }
  local closed = M.tab_close({ block_id = "block:1" })
  t.check("the tab closed", closed.closed == true and closed.block_id == "block:2", closed.block_id)
  local lines = t.read_file(tabs_file())
  t.check("and left the registry", lines == "block:1\t9317\thttps://a.example/\n", lines)

  fake.pick_answers = { { value = nil, reason = "cancelled" } }
  local none = M.tabs({ block_id = "block:1" })
  t.check("cancelling changes nothing", none.switched == false and none.reason == "cancelled", none.reason)
end

t.section("a tab whose block is gone is dropped from the registry")
do
  local M = fresh()
  -- block:2 is in a window, block:3 is not: only the first is a live tab.
  write_tabs({ "block:2\t9318\thttps://live.example/", "block:3\t9319\thttps://gone.example/" })

  fake.pick_answers = { { value = "block:2" } }
  M.tabs({ block_id = "block:1" })
  local pick = fake:last_call("pick")
  t.check("the picker offers only the live tab", #pick.spec.items == 1, #pick.spec.items)
  t.check("and the registry keeps only it", t.read_file(tabs_file()) == "block:2\t9318\thttps://live.example/\n",
    t.read_file(tabs_file()))

  write_tabs({ "block:3\t9317\thttps://gone.example/" })
  local result = M.tab_new({ block_id = "block:1" }, "https://example.com/")
  t.check("a dead tab's port is free again", result.port == 9317, result.port)
end

t.section("a registry full of dead tabs says so plainly")
do
  local M = fresh()
  write_tabs({ "block:99\t9320\thttps://gone.example/" })
  local err = t.error_of(M.tabs, { block_id = "block:1" })
  t.check("the error says there are none", err and err:find("no Ladybird tabs are recorded", 1, true) ~= nil, err)
  t.check("and the registry is emptied", t.read_file(tabs_file()) == "", t.read_file(tabs_file()))
end

--- History ---------------------------------------------------------------

t.section("the address picker reads history from both browsers")
do
  local M = fresh()
  local chrome = fake.tmp .. "/chrome/History"
  local ladybird = fake.tmp .. "/profile/data/History.db"
  fake:on_exec("/bin/test -r " .. chrome, { ok = true, stdout = "" })
  fake:on_exec("/bin/test -r " .. ladybird, { ok = true, stdout = "" })
  fake:on_exec("/usr/bin/sqlite3", function(argv)
    if argv[#argv]:find(" from urls", 1, true) then
      return { ok = true, stdout = table.concat({
        "https://a.example/\tA",
        "https://a.example/\tA repeated",
        "https://b.example/\tB",
        "about:blank\tBlank",
        "",
      }, "\n") }
    end
    return { ok = true, stdout = "https://c.example/\tC\nhttps://a.example/\tA again\n" }
  end)

  fake.pick_answers = { { value = "https://b.example/" } }
  local result = M.open({ block_id = "block:1" })
  local pick = fake:last_call("pick")
  local ids = {}
  for _, item in ipairs(pick.spec.items) do ids[#ids + 1] = item.id end
  t.check("history keeps a title for every row", pick.spec.items[1].title == "A", pick.spec.items[1].title)
  t.check("duplicates are dropped", #ids == 3, table.concat(ids, ", "))
  t.check("both databases are read, Chrome first",
    table.concat(ids, " ") == "https://a.example/ https://b.example/ https://c.example/", table.concat(ids, " "))
  t.check("typed addresses are allowed", pick.spec.allow_other == true, tostring(pick.spec.allow_other))
  t.check("the choice is opened", result.opened == true and result.url == "https://b.example/", result.url)

  fake.pick_answers = { { value = "how tall is everest" } }
  M.open({ block_id = "block:1" })
  local data = last_write()
  t.check("free text is passed through to the search handler",
    data == "\27_ladybird;open;how tall is everest\27\\", data)
end

t.section("the current page is offered first")
do
  local M = fresh()
  fake:set_status("block:1", "Example Domain — https://example.com/current   ctrl-l url · ctrl-r reload")
  fake.pick_answers = { { value = nil, reason = "cancelled" } }
  t.error_of(M.open, { block_id = "block:1" })
  local pick = fake:last_call("pick")
  t.check("the picker is titled for this pane", pick.spec.title ~= nil, pick.spec.title)
  t.check("and the current address is in the list", pick.spec.items[1] and pick.spec.items[1].id == "https://example.com/current",
    pick.spec.items[1] and pick.spec.items[1].id)
end

--- Reading the address ---------------------------------------------------

t.section("the address comes from devtools, then the status line")
do
  local M = fresh()
  fake:on_exec("/tmp/ladyctl tabs", { ok = true, stdout = "Example Domain — https://example.com/\n" })
  local result = M.url({ block_id = "block:1" })
  t.check("devtools is preferred", result.url == "https://example.com/" and result.source == "devtools", result.source)

  local M2 = fresh()
  fake:set_status("block:1", "Example Domain — https://example.com/deep/path   ctrl-l url · ctrl-r reload")
  local fallback = M2.url({ block_id = "block:1" })
  t.check("the status line is the fallback",
    fallback.url == "https://example.com/deep/path" and fallback.source == "status-line",
    tostring(fallback.url) .. " via " .. tostring(fallback.source))
end

--- Registration ----------------------------------------------------------

t.section("every action is registered and callable")
do
  local M = fresh()
  local names = {}
  for name in pairs(fake.actions) do names[#names + 1] = name end
  table.sort(names)
  t.check("seven actions", #names == 7, table.concat(names, ", "))

  -- Regression: the tab action reaches its helpers. A local defined after the
  -- action that calls it is nil, and only a real call shows that.
  fake.pick_answers = { { value = "https://example.com/picked" } }
  local ok, result = pcall(fake.actions.ladybird_tab_new.run, { block_id = "block:1" }, nil)
  t.check("the tab action runs end to end", ok and result.opened == true, tostring(result))

  -- No panes left: every block is gone and the remembered one is forgotten.
  fake.process, fake.status = {}, {}
  os.execute("rm -rf '" .. state_dir() .. "'")
  for _, session in ipairs(fake.sessions) do
    for _, window in ipairs(session.windows) do
      for _, layer in ipairs(window.layers) do layer.blocks = {} end
    end
  end
  local ok2, err2 = pcall(fake.actions.ladybird_url.run, { block_id = "block:1" }, nil)
  t.check("the copy action reports a missing pane", ok2 == false and tostring(err2):find("no Ladybird", 1, true) ~= nil,
    tostring(err2))
end

t.done()
