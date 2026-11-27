-- TUI launcher: pick a tool you actually use, and run it in the focused pane's
-- folder. The index comes from shell history (atuin), so it is made of the
-- programs you run, not of a list someone maintains.
--
--   rex do extensions/tui-launcher/init.lua --action tui_launcher
--
-- From init.lua, to bind it:
--   require("tui-launcher")          -- defines the action, binds nothing
--   rex.bind("ctrl+b>a", "tui_launcher")
--
-- Dry run, which prints the index instead of opening the picker:
--   TUI_LAUNCHER_DRY=1 rex do extensions/tui-launcher/init.lua --action tui_launcher
--
-- It reads rex.json, rex.invoke and the client keymap, so it only runs under a
-- real Rex; test/launcher_test.lua is the check, and it needs one too.

local HISTORY_DB = os.getenv("TUI_LAUNCHER_DB")
  or ((os.getenv("XDG_DATA_HOME") or (os.getenv("HOME") .. "/.local/share")) .. "/atuin/history.db")

-- A tool is offered when it ran at least MIN_RUNS times, last ran within
-- MAX_AGE_DAYS, and at least MIN_SHARE of those runs lasted LONG_RUN_SECONDS
-- or more. That share is what separates a TUI from `ls`: one-shot commands
-- almost never sit for two seconds (`cd` scores 0.01, `git` 0.25, `pi` 0.58,
-- `ssh` 0.92). The blocklist below is for the long runners that are still not
-- tools to launch: a watcher, a build, a shell.
local MIN_RUNS = 3
local MAX_AGE_DAYS = 180
local RECENT_DAYS = 30
local LONG_RUN_SECONDS = 2
local MIN_SHARE = 0.35
local MIN_LONG_RUNS = 2
local MAX_ITEMS = 2000

local NEVER = {}
for word in ([[
  bash sh zsh fish dash env printenv source exec eval command time history exit
  cd ls cat tac echo printf rm mv cp mkdir rmdir touch ln chmod chown stat open file
  sleep tail head less more man watch caffeinate
  brew nix nix-shell just make cmake ninja bazel gradle mvn java
  docker kubectl helm kind minikube systemctl launchctl defaults tccutil
  npm npx pnpm yarn bun uv uvx pip pipx python python3 node deno dotnet go cargo
  curl wget scp rsync ssh-copy-id ssh-add ssh-keygen ping dig nc
  git jj gh cf wrangler sops tldr sudo su
  lsof uname whoami df du dmesg log journalctl ps kill top-free julia log
  terraform pulumi aws gcloud az ansible vagrant
  bat tree dust duf fastfetch chafa delta lesspipe
]]):gmatch("%S+") do
  NEVER[word] = true
end

-- Tools whose arguments name a target deserve a row per target, not one row
-- for the tool: ssh to one host is a different thing from ssh to another. The
-- value is how many of a tool's most used invocations to offer.
local VARIANTS = { ssh = 4, mosh = 4, telnet = 3 }

-- What a pick runs, when the most-used line in history is not what you want
-- from a launcher. Each entry replaces that tool's usual line.
local RUN_AS = {
  -- vim = "vim",
  -- ssh = "ssh framearch-juan",
}

-- Icons come from a fixed set: document, folder, branch, terminal, code, server,
-- database, package, globe, link, person, tag, clock, star, gear, plus.
local ICONS = {
  ssh = "server", mosh = "server", telnet = "server",
  vim = "code", nvim = "code", vi = "code", helix = "code", hx = "code",
  pi = "code", claude = "code", codex = "code", agy = "code", opencode = "code",
  copilot = "code", cursor = "code", vib = "code",
  lazygit = "branch", tig = "branch", gitui = "branch",
  yazi = "folder", nnn = "folder", ranger = "folder", fm = "folder", lf = "folder",
  btop = "star", htop = "star", top = "star", btm = "star", bottom = "star",
  psql = "database", sqlite3 = "database", mycli = "database", litecli = "database",
  atuin = "clock", k9s = "package", lazydocker = "package",
}

local function exec_ok(program, ...)
  local argv = { program }
  for _, value in ipairs({ ... }) do argv[#argv + 1] = value end
  local result, err = rex.exec(argv)
  if not result then return nil, err end
  if not result.ok then return nil, (result.stderr or ""):gsub("%s+$", "") end
  return result.stdout
end

local function sqlite()
  for _, candidate in ipairs{ "/usr/bin/sqlite3", "/opt/homebrew/bin/sqlite3" } do
    local probe = rex.exec({ "/bin/test", "-x", candidate })
    if probe and probe.ok then return candidate end
  end
  local found = exec_ok("/bin/sh", "-lc", "command -v sqlite3")
  if found and found:match("%S") then return found:match("^%s*(%S+)") end
  return nil, "sqlite3 not found"
end

-- One row per program: how often, how long, and when it last ran.
local function history_query(column_set, extra)
  local sql = "with c as ("
    .. " select trim(command) as command, duration, timestamp from history"
    .. " where deleted_at is null and instr(command, char(10)) = 0 and trim(command) <> ''"
    .. "), b as ("
    .. " select command, case when instr(command, ' ') > 0"
    .. "   then substr(command, 1, instr(command, ' ') - 1) else command end as bin,"
    .. " duration, timestamp from c)"
    .. " select " .. column_set .. " from b" .. (extra or "")
  return sql
end

local function read_history()
  local binary, err = sqlite()
  if not binary then return nil, err end
  local probe = rex.exec({ "/bin/test", "-f", HISTORY_DB })
  if not probe or not probe.ok then return nil, "no history database at " .. HISTORY_DB end

  local rows_text, query_err = exec_ok(binary, "-readonly", "-json", HISTORY_DB,
    history_query("bin, count(*) n, sum(duration >= " .. (LONG_RUN_SECONDS * 1000000000)
        .. ") long, max(timestamp) last",
      " group by bin having n >= " .. MIN_RUNS .. " and long >= " .. MIN_LONG_RUNS))
  if not rows_text then return nil, query_err or "history query failed" end
  local rows = rex.json.decode(rows_text) or {}

  local now = os.time()
  local cutoff = (now - RECENT_DAYS * 86400) * 1000000000
  local recent_text = exec_ok(binary, "-readonly", "-json", HISTORY_DB,
    history_query("bin, count(*) n", " where timestamp > " .. string.format("%d", cutoff) .. " group by bin")) or "[]"
  local recent = {}
  for _, row in ipairs(rex.json.decode(recent_text) or {}) do
    recent[row.bin] = row.n
  end

  -- SQLite gives the bare `command` the row of the max(), which is the usual
  -- way this program was run.
  local usual_text = exec_ok(binary, "-readonly", "-json", HISTORY_DB,
    "with c as ("
      .. " select trim(command) as command, timestamp from history"
      .. " where deleted_at is null and instr(command, char(10)) = 0 and trim(command) <> ''"
      .. "), b as ("
      .. " select command, case when instr(command, ' ') > 0"
      .. "   then substr(command, 1, instr(command, ' ') - 1) else command end as bin, timestamp from c),"
      .. " g as (select bin, command, count(*) n, max(timestamp) last from b group by bin, command),"
      .. " r as (select bin, command, n, last, row_number() over (partition by bin order by n desc, last desc) rank"
      .. "   from g) select bin, command, n, last from r where rank <= 5 order by bin, rank") or "[]"
  local usual, variants = {}, {}
  for _, row in ipairs(rex.json.decode(usual_text) or {}) do
    if usual[row.bin] == nil then usual[row.bin] = row.command end
    local list = variants[row.bin] or {}
    variants[row.bin] = list
    list[#list + 1] = { command = row.command, n = row.n, last = row.last,
      age_days = (now * 1000000000 - (row.last or 0)) / 86400000000000 }
  end

  local now_ns = now * 1000000000
  local tools = {}
  local rejected = {}
  for _, row in ipairs(rows) do
    local bin = row.bin
    local runs = row.n
    local long = row.long or 0
    local share = runs > 0 and (long / runs) or 0
    local age_days = (now_ns - (row.last or 0)) / 86400000000000
    local usable = bin
      and not NEVER[bin]
      and not NEVER[bin:match("([^/]+)$") or bin]
      and bin:match("^[%w%._/@%+%-]+$")
      and bin:sub(1, 1) ~= "-"
      and runs >= MIN_RUNS
      and long >= MIN_LONG_RUNS
      and share >= MIN_SHARE
      and age_days <= MAX_AGE_DAYS
    if usable then
      tools[#tools + 1] = {
        bin = bin, runs = runs, long = long, age_days = age_days,
        recent = recent[bin] or 0, line = RUN_AS[bin] or usual[bin] or bin,
        variants = variants[bin] or {},
      }
    else
      local reason
      if not bin or not bin:match("^[%w%._/@%+%-]+$") or bin:sub(1, 1) == "-" then
        reason = "not a plain program name"
      elseif NEVER[bin] or NEVER[bin:match("([^/]+)$") or bin] then
        reason = "on the never list"
      elseif runs < MIN_RUNS then
        reason = string.format("only %d run(s)", runs)
      elseif long < MIN_LONG_RUNS or share < MIN_SHARE then
        reason = string.format("%.2f of runs lasted %ds", share, LONG_RUN_SECONDS)
      elseif age_days > MAX_AGE_DAYS then
        reason = string.format("last ran %d days ago", math.floor(age_days))
      end
      if reason then rejected[#rejected + 1] = { bin = bin, reason = reason } end
    end
  end
  return tools, rejected
end

-- One login shell resolves every candidate, so 40 programs cost one process.
-- The extra directories matter: the server starts without the PATH an
-- interactive shell has, and ~/.local/bin is often only added there.
local EXTRA_PATH = {
  "$HOME/.local/bin", "$HOME/bin", "$HOME/.nix-profile/bin",
  "/opt/homebrew/bin", "/usr/local/bin", "/run/current-system/sw/bin",
}
local function keep_available(tools)
  if #tools == 0 then return tools end
  local names = {}
  for _, tool in ipairs(tools) do names[#names + 1] = tool.bin end
  local script = 'PATH="' .. table.concat(EXTRA_PATH, ":") .. ':$PATH"; for b in '
    .. table.concat(names, " ")
    .. '; do command -v -- "$b" >/dev/null 2>&1 && echo "$b"; done'
  local out = exec_ok(os.getenv("SHELL") or "/bin/sh", "-lc", script) or ""
  local present = {}
  for name in out:gmatch("%S+") do present[name] = true end
  local kept = {}
  for _, tool in ipairs(tools) do
    if present[tool.bin] then kept[#kept + 1] = tool end
  end
  return kept
end

local function describe_age(days)
  if days < 1 then return "today" end
  if days < 30 then return string.format("%dd", math.floor(days + 0.5)) end
  if days < 365 then return string.format("%dmo", math.floor(days / 30 + 0.5)) end
  return string.format("%dy", math.floor(days / 365 + 0.5))
end

local function shorten(text, limit)
  if #text <= limit then return text end
  return text:sub(1, limit - 1) .. "…"
end

-- The focused pane's folder, so a picked tool opens where you were working.
local function terminal_cwd(block_id)
  if not block_id then return nil end
  local creator = "com.superlogical.terminal"
  local function absolute(path)
    return type(path) == "string" and path:sub(1, 1) == "/" and not path:find("%z")
  end
  local proc = rex.block.call(creator, "process", { block_id = block_id }) or {}
  for _, candidate in ipairs{ (proc.foreground or {}).cwd, (proc.child or {}).cwd } do
    if absolute(candidate) then return candidate end
  end
  local reported = rex.block.call(creator, "pwd", { block_id = block_id }) or {}
  local pwd = reported.pwd
  if absolute(pwd) then return pwd end
  if type(pwd) ~= "string" then return nil end
  local host, path = pwd:match("^file://([^/]*)(/[^?#]*)$")
  if not path then return nil end
  host = host:lower()
  if host ~= "" and host ~= "localhost" then
    local name = (exec_ok("/bin/hostname") or ""):match("^%s*(%S+)")
    local alias = (exec_ok("/usr/sbin/scutil", "--get", "LocalHostName") or ""):match("^%s*(%S+)")
    if not name or (host ~= name:lower() and (not alias or host ~= alias:lower() .. ".local")) then
      return nil
    end
  end
  path = path:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
  if absolute(path) then return path end
end

-- One tab in a folder, with nothing typed into it yet.
local function open_tab(ctx, cwd, label)
  local created, err = rex.session.new_window{
    session_id = ctx and ctx.session_id,
    window_label = label,
    focus = true,
    layout = rex.layout.block{
      flavor = "com.superlogical.terminal.shell",
      label = label,
      options = { cwd = cwd },
    },
  }
  if not created then error(err or "could not open a tab") end
  local block_id = created.block_ids and created.block_ids[1]
  if not block_id then error("the new tab reported no block") end
  return block_id, created.window_id
end

-- Open a shell tab in the folder, then type the command at its prompt, so
-- quitting the tool leaves a shell in that folder instead of a dead block.
-- The write goes out as soon as the block exists: the pty buffers it until the
-- shell reads. Sleeping first is not an option, because an action cannot pause.
local function launch(ctx, command, label)
  local cwd = terminal_cwd(ctx and ctx.block_id)
  local block_id, window_id = open_tab(ctx, cwd, label)
  local written, write_err = rex.block.call("com.superlogical.terminal", "write",
    { block_id = block_id, data = command .. "\r" })
  if written == nil then error(write_err or "could not type the command") end
  return { command = command, cwd = cwd, block_id = block_id, window_id = window_id }
end

local function open_folder(ctx, path, label)
  local block_id, window_id = open_tab(ctx, path, label)
  return { cwd = path, block_id = block_id, window_id = window_id }
end

local function expand_home(text)
  local home = os.getenv("HOME")
  if not home then return text end
  if text == "~" then return home end
  if text:sub(1, 2) == "~/" then return home .. text:sub(2) end
  return text
end

-- Typed text is routed by what it looks like, so the box opens pages, folders
-- and programs alike.
local function route_text(text)
  if text:match("^%a[%w+.-]*://") or text:match("^mailto:%S") then
    return { kind = "url", text = text }
  end
  local path = expand_home(text)
  if path:sub(1, 1) == "/" then
    local directory = rex.exec({ "/bin/test", "-d", path })
    if directory and directory.ok then return { kind = "folder", path = path } end
    local file = rex.exec({ "/bin/test", "-f", path })
    if file and file.ok then
      return { kind = "folder", path = (path:match("^(.*)/[^/]*$") or "/") }
    end
  end
  return { kind = "command", text = text }
end

-- A URL goes to Ladybird when that plugin is installed, and to the system's
-- opener otherwise.
local function open_url(text)
  for _, action in ipairs((rex.call("client.keymap") or {}).actions or {}) do
    if action.name == "ladybird_open" then
      local _, problem = rex.invoke("ladybird_open", { url = text })
      if problem then error(tostring(problem)) end
      return { url = text, opened_with = "ladybird_open" }
    end
  end
  local opened, problem = rex.exec({ "/usr/bin/open", text })
  if not opened or not opened.ok then
    error((problem or (opened and opened.stderr) or "could not open") .. " " .. text)
  end
  return { url = text, opened_with = "open" }
end

-- Rex actions are the second source: the plugins you already have (Ladybird,
-- worktree, project todos) become rows in the same list. Picking one runs it.
local ACTION_ICONS = {
  Browser = "globe", Worktree = "branch", Session = "terminal",
  Appearance = "star", Project = "folder", Launch = "terminal",
}

local function append_actions(items, lines)
  local keymap = rex.call("client.keymap") or {}
  local added = 0
  for _, action in ipairs(keymap.actions or {}) do
    -- Dotted names belong to clients and block creators, not to init.lua, and
    -- only init.lua actions can be run with rex.invoke.
    if action.name ~= "tui_launcher" and not action.name:find("%.", 1) then
      local id = "rex:" .. action.name
      local category = action.category or "Actions"
      items[#items + 1] = {
        id = id,
        title = action.title or action.name,
        subtitle = "Rex action · " .. category,
        icon = ACTION_ICONS[category] or "gear",
        detail = "action",
      }
      lines[id] = id
      added = added + 1
    end
  end
  return added
end

-- Sessions are the third source: the same list cmd+p builds, reachable from the
-- same box. Picking one asks the app to show it.
local function append_sessions(items, lines)
  local sessions = rex.call("session.list") or {}
  for _, session in ipairs(sessions.sessions or {}) do
    local id = "session:" .. session.session_id
    items[#items + 1] = {
      id = id,
      title = session.label or session.session_id,
      subtitle = "Rex session",
      icon = "terminal",
      detail = "session",
    }
    lines[id] = session.session_id
  end
end

-- Apps are the fourth: the bundles in the two Applications folders, launched
-- with open rather than typed into a terminal. About 150 rows on a normal Mac,
-- and the picker filters locally, so they cost nothing until typed at.
local function append_apps(items, lines)
  local listing = exec_ok("/bin/sh", "-c",
    'ls -1d /Applications/*.app /Applications/Utilities/*.app "$HOME"/Applications/*.app 2>/dev/null') or ""
  local seen = {}
  for path in listing:gmatch("[^\n]+") do
    local name = path:match("([^/]+)%.app$")
    if name and not seen[name] then
      seen[name] = true
      local id = "app:" .. name
      items[#items + 1] = {
        id = id,
        title = name,
        subtitle = "Application",
        icon = "package",
        detail = "app",
      }
      lines[id] = path
    end
  end
end

local function build_index()
  local tools, rejected = read_history()
  if not tools then error(rejected or "could not read shell history") end
  local available = keep_available(tools)
  local present = {}
  for _, tool in ipairs(available) do present[tool.bin] = true end
  for _, tool in ipairs(tools) do
    if not present[tool.bin] then
      rejected[#rejected + 1] = { bin = tool.bin, reason = "not installed" }
    end
  end
  tools = available
  table.sort(tools, function(a, b)
    local sa, sb = a.recent * 3 + a.runs, b.recent * 3 + b.runs
    if sa ~= sb then return sa > sb end
    return a.bin < b.bin
  end)
  local items, lines = {}, {}
  for _, tool in ipairs(tools) do
    if #items >= MAX_ITEMS then break end
    local subtitle = tool.line ~= tool.bin and ("usual: " .. shorten(tool.line, 64)) or tool.bin
    items[#items + 1] = {
      id = tool.bin,
      title = tool.bin,
      subtitle = subtitle,
      icon = ICONS[tool.bin] or "terminal",
      detail = string.format("%d×  %s", tool.runs, describe_age(tool.age_days)),
    }
    lines[tool.bin] = tool.line
    local wanted = VARIANTS[tool.bin] or 0
    if wanted > 0 then
      local shown = 1
      for _, variant in ipairs(tool.variants or {}) do
        if shown >= wanted then break end
        if variant.command ~= tool.line then
          shown = shown + 1
          local target = variant.command:match("^%S+%s+(.*)$") or variant.command
          local id = "line:" .. variant.command
          items[#items + 1] = {
            id = id,
            title = shorten(target, 40),
            subtitle = tool.bin .. " · usual",
            icon = ICONS[tool.bin] or "terminal",
            detail = string.format("%d×  %s", variant.n, describe_age(variant.age_days)),
          }
          lines[id] = variant.command
        end
      end
    end
  end
  append_actions(items, lines)
  append_sessions(items, lines)
  append_apps(items, lines)
  table.sort(rejected, function(a, b)
    return (a.bin or "") < (b.bin or "")
  end)
  return items, lines, rejected
end

rex.action{
  name = "tui_launcher",
  title = "Launch: pick a tool…",
  description = "Pick a program from your shell history and run it in the focused pane's folder.",
  category = "Launch",
  keywords = "launcher alfred run tui app open command history atuin",
  -- pick runs a tool by name without asking, for the CLI and for launchers
  -- such as Raycast: rex do tui_launcher pick=btop
  -- command runs any line without asking: rex do tui_launcher command='lazygit'
  -- dry prints the index instead of opening the picker.
  args = { pick = "string?", command = "string?", dry = "boolean?" },
  run = function(ctx, args)
    local started = os.clock()
    local items, lines, rejected = build_index()
    local elapsed = os.clock() - started
    if #items == 0 then
      error("no tools in " .. HISTORY_DB .. " passed the filter")
    end
    local dry = (args and args.dry) or os.getenv("TUI_LAUNCHER_DRY")
    local from_command_line = args and args.command and args.command ~= ""
    if dry and not from_command_line then
      return {
        index_ms = math.floor(elapsed * 1000 + 0.5),
        count = #items,
        items = items,
        rejected = rejected,
        dry_run = true,
      }
    end

    local command, chosen
    local wanted = args and args.pick
    if args and args.command and args.command ~= "" then
      command = args.command
    elseif wanted and wanted ~= "" then
      local bin = lines[wanted] and wanted
      if not bin then
        local matches = {}
        for candidate in pairs(lines) do
          -- Match the whole id or what follows its kind, so pick=Safari finds
          -- app:Safari and pick=worktree finds rex:worktree.
          local bare = candidate:match("^%a+:(.*)$") or candidate
          if candidate:sub(1, #wanted) == wanted or bare:sub(1, #wanted) == wanted then
            matches[#matches + 1] = candidate
          end
        end
        table.sort(matches)
        if #matches > 1 then error(wanted .. " matches " .. table.concat(matches, ", ")) end
        bin = matches[1]
      end
      if not bin then
        local names = {}
        for _, item in ipairs(items) do
          if #names >= 12 then break end
          names[#names + 1] = item.title
        end
        error("no tool matches " .. wanted .. "; try one of " .. table.concat(names, ", "))
      end
      chosen = bin
      command = lines[bin]
    else
      local choice, why, detail = rex.ui.pick{
        title = "Launch",
        placeholder = "Filter tools, or type a command, path or URL",
        allow_other = true,
        items = items,
      }
      if choice == nil then
        if why == "cancelled" then return { cancelled = true } end
        if why == "unsupported" or why == "no_client" then
          error("launcher: no connected Rex app can show a prompt (" .. tostring(why)
            .. "); an app older than the server cannot, so update the app, or drive this"
            .. " from the CLI with pick=NAME")
        end
        error("launcher prompt: " .. tostring(why) .. (detail and (" " .. detail) or ""))
      end
      if type(choice) == "table" then
        command = choice.text
      else
        chosen, command = choice, (lines[choice] or choice)
      end
    end

    if not command or command == "" then return { cancelled = true } end

    -- Typed text is not an id, so route it by shape before anything else.
    if not chosen then
      local route = route_text(command)
      if dry then return { route = route.kind, target = route.path or route.text } end
      if route.kind == "url" then
        local result = open_url(route.text)
        result.index_ms = math.floor(elapsed * 1000 + 0.5)
        return result
      end
      if route.kind == "folder" then
        local result = open_folder(ctx, route.path, shorten(command, 32))
        result.index_ms = math.floor(elapsed * 1000 + 0.5)
        return result
      end
    end

    local target = chosen or command
    if target:match("^session:") then
      local session_id = lines[target]
      if not session_id then error("no session named " .. target:sub(9)) end
      local ok, problem = pcall(rex.client.queue, "session.select", { session_id = session_id })
      if not ok then error(tostring(problem)) end
      return { session = session_id, index_ms = math.floor(elapsed * 1000 + 0.5) }
    end
    if target:match("^app:") then
      local path = lines[target]
      if not path then error("no app named " .. target:sub(5)) end
      local opened, problem = rex.exec({ "/usr/bin/open", "-a", path })
      if not opened or not opened.ok then
        error((problem or (opened and opened.stderr) or "could not open ") .. " " .. tostring(path))
      end
      return { app = target:sub(5), index_ms = math.floor(elapsed * 1000 + 0.5) }
    end
    if target:match("^rex:") then
      local name = target:sub(5)
      -- rex.invoke returns a second value only when the action did not run, and
      -- a person who cancels the action it opens is not a failure.
      local _, problem = rex.invoke(name)
      if problem then error(tostring(problem)) end
      return { action = name, index_ms = math.floor(elapsed * 1000 + 0.5) }
    end
    local result = launch(ctx, command, shorten(command, 32))
    result.index_ms = math.floor(elapsed * 1000 + 0.5)
    return result
  end,
}
