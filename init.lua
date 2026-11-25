-- Rex integration for Ladybird's terminal mode (--headless=terminal).
--
-- Rex owns the pickers and the layout; Ladybird owns the page. Navigation is
-- handed to the browser over the same APC command channel its status line
-- documents (ESC _ ladybird;open;<url> ESC \), so nothing has to be typed into
-- the terminal and the address bar can be a native Rex picker instead.

local TERMINAL_CREATOR = "com.superlogical.terminal"
local HOME = os.getenv("HOME")
-- Where this file lives, so the helpers in bin/ are found from a checkout as well
-- as from ~/.config/rex.
local MODULE_DIR = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):match("^(.*)/[^/]*$")
  or (HOME .. "/.config/rex/rex-ladybird")
local STATE_DIR = (os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")) .. "/rex-ladybird"
local STATE_FILE = STATE_DIR .. "/current"
local PORT_FILE = STATE_DIR .. "/port"
local TABS_FILE = STATE_DIR .. "/tabs"

local function executable(path)
  local probe = rex.exec({ "/bin/test", "-x", path })
  return probe ~= nil and probe.ok
end

-- The absolute path `command -v` prints for a program on PATH, or nil.
local function on_path(name)
  local probe = rex.exec({ "/bin/sh", "-c", "command -v " .. name })
  if probe == nil or not probe.ok then return nil end
  local path = (probe.stdout or ""):gsub("%s+$", "")
  if path == "" then return nil end
  return path
end

-- The first path in the list that can be opened for reading. Used for files a
-- browser owns, so a missing candidate is ordinary rather than an error.
local function first_existing(paths)
  for _, path in ipairs(paths) do
    local file = io.open(path, "r")
    if file then
      file:close()
      return path
    end
  end
end

local M = {
  options = {
    -- The build with the status-line patch; falls back to the installed app when
    -- this path is missing (see README, "Hiding terminal mode's own status line").
    -- An explicit LADYBIRD_BINARY wins, then a development build in the usual
    -- places, then the installed app, then whatever PATH offers. A terminal-mode
    -- build is required: a release .dmg will not do.
    binary = (function()
      local override = os.getenv("LADYBIRD_BINARY")
      if override ~= nil and override ~= "" then return override end
      for _, built in ipairs{
        HOME .. "/projects/ladybird/Build/release/bin/Ladybird.app/Contents/MacOS/Ladybird",
        HOME .. "/ladybird/Build/release/bin/Ladybird.app/Contents/MacOS/Ladybird",
        HOME .. "/src/ladybird/Build/release/bin/Ladybird.app/Contents/MacOS/Ladybird",
        "/Applications/Ladybird.app/Contents/MacOS/Ladybird",
      } do
        if executable(built) then return built end
      end
      return on_path("ladybird") or "/Applications/Ladybird.app/Contents/MacOS/Ladybird"
    end)(),
    profile = (os.getenv("XDG_DATA_HOME") or (HOME .. "/.local/share"))
      .. "/ladybird-terminal-profile",
    device_pixel_ratio = 2,
    label = "Ladybird",
    devtools_port = 9317,
    -- Requires the status-line patch (chrome command); a no-op on a stock build
    -- other than a five second "unknown command: chrome" notice.
    hide_status_line = true,
    ladyctl = (function()
      local beside = MODULE_DIR .. "/bin/ladyctl"
      if executable(beside) then return beside end
      return HOME .. "/.local/bin/ladyctl"
    end)(),
    -- Whichever of the common Chrome-family histories this machine has. The
    -- picker treats a missing file as an empty history, so the first candidate
    -- is a harmless default.
    chrome_history = first_existing{
      HOME .. "/Library/Application Support/Google/Chrome/Default/History",
      HOME .. "/Library/Application Support/Chromium/Default/History",
      HOME .. "/.config/google-chrome/Default/History",
      HOME .. "/.config/chromium/Default/History",
      HOME .. "/.config/BraveSoftware/Brave-Browser/Default/History",
      HOME .. "/.config/microsoft-edge/Default/History",
    } or (HOME .. "/Library/Application Support/Google/Chrome/Default/History"),
    history_items = 400,
  },
}

local function raise(message)
  error(message, 0)
end

local function run(argv, timeout)
  local result = rex.exec(argv, { timeout = timeout })
  if result == nil then return nil, "could not run " .. argv[1] end
  if not result.ok then return nil, (result.stderr or ""):gsub("%s+$", "") end
  return result.stdout or ""
end

local function file_is_readable(path)
  local result = rex.exec({ "/bin/test", "-r", path })
  return result ~= nil and result.ok
end

-- Read a history database without opening it read-write: Chrome holds a lock on
-- its own copy, and immutable=1 also keeps us from touching its WAL.
local function history_rows(database, query)
  if not file_is_readable(database) then return nil end
  return run({ "/usr/bin/sqlite3", "-separator", "\t", "-noheader", "file:" .. database .. "?immutable=1", query })
end

local function split_rows(stdout)
  local rows = {}
  for line in (stdout or ""):gmatch("[^\n]+") do
    local url, title = line:match("^([^\t]*)\t?(.*)$")
    if url and url:match("^%a[%w+.-]*://") then
      rows[#rows + 1] = { id = url, title = (title ~= "" and title) or url, subtitle = url, icon = "globe" }
    end
  end
  return rows
end

-- Browsing history from both browsers, Chrome first because it usually has the
-- longer tail. Duplicates keep the first (most recent) title seen.
local function history_items()
  local items, seen = {}, {}
  local sources = {
    {
      M.options.chrome_history,
      "select url, replace(replace(coalesce(title, ''), char(9), ' '), char(10), ' ') from urls"
        .. " order by last_visit_time desc limit " .. M.options.history_items,
    },
    {
      M.options.profile .. "/data/History.db",
      "select url, replace(replace(coalesce(title, ''), char(9), ' '), char(10), ' ') from Items"
        .. " order by last_visit_time desc limit " .. M.options.history_items,
    },
  }
  for _, source in ipairs(sources) do
    local stdout = history_rows(source[1], source[2])
    for _, item in ipairs(split_rows(stdout)) do
      if not seen[item.id] then
        seen[item.id] = true
        items[#items + 1] = item
      end
    end
  end
  return items
end

local function ladybird_blocks()
  local blocks = {}
  local sessions = rex.call("session.list") or {}
  for _, session in ipairs(sessions.sessions or {}) do
    local view = rex.call("session.view", { session_id = session.session_id }) or {}
    for _, window in ipairs(view.windows or {}) do
      for _, layer in ipairs(window.layers or {}) do
        for _, block in ipairs(layer.blocks or {}) do
          local label = block.label or ""
          if block.creator_name == TERMINAL_CREATOR and label:sub(1, #M.options.label) == M.options.label then
            blocks[#blocks + 1] = { block_id = block.block_id, exact = label == M.options.label }
          end
        end
      end
    end
  end
  return blocks
end

local function status_text(block_id)
  local result = rex.block.call(TERMINAL_CREATOR, "format", {
    block_id = block_id,
    format = "text",
    trim = true,
  })
  local content = type(result) == "table" and result.content or nil
  if type(content) ~= "string" then return nil end
  return content
end

-- The status line is "<title> — <url>   ctrl-l url · ...", so the last
-- non-empty row that ends in the shortcut hint carries the current URL.
local function current_url(block_id)
  local content = status_text(block_id)
  if not content then return nil end
  local url
  for line in content:gmatch("[^\n]+") do
    local candidate = line:match("—%s+(%a[%w+.-]*://[^%s]+)")
    if candidate then url = candidate end
  end
  return url
end

local function process_path(block_id)
  local process = rex.block.call(TERMINAL_CREATOR, "process", { block_id = block_id })
  if type(process) ~= "table" then return nil end
  local foreground = process.foreground or process.child
  if type(foreground) ~= "table" then return nil end
  return foreground.argv0 or foreground.invoked_path
end

-- Ask the block what it is running rather than reading its status line: the line
-- is cut to the pane width, so its trailing hints disappear in narrow panes.
local function is_ladybird(block_id)
  local path = process_path(block_id)
  if path then
    return path:find("/Ladybird.app/", 1, true) ~= nil or path:match("/Ladybird$") ~= nil
  end
  local content = status_text(block_id)
  return content ~= nil and content:find("ctrl%-l url", 1, true) ~= nil
end

-- The block last driven by an action, so an action finds the same pane again
-- even when several Ladybird panes are open in different sessions.
local function remembered_block()
  local file = io.open(STATE_FILE, "r")
  if not file then return nil end
  local block_id = file:read("*l")
  file:close()
  if type(block_id) == "string" and block_id ~= "" then return block_id end
  return nil
end

local function write_state(path, value)
  rex.exec({ "/bin/mkdir", "-p", STATE_DIR })
  local file = io.open(path, "w")
  if not file then return end
  file:write(tostring(value), "\n")
  file:close()
end

local function remember_block(block_id)
  write_state(STATE_FILE, block_id)
end

local function remember_port(port)
  write_state(PORT_FILE, port)
end

-- Ask ladyctl for the real URL and title over the DevTools server. The status
-- line is truncated to the pane width, so it is only a fallback.
local function devtools_metadata()
  local stdout = run({ M.options.ladyctl, "tabs" })
  if not stdout then return nil end
  local title, url = stdout:match("^(.-) — (https?://%S+)")
  if not url then return nil end
  return { title = title, url = url }
end

-- The block to drive: the focused one when it is a Ladybird pane, then the one
-- an earlier action used, then any Ladybird pane that is still alive.
local function target_block(ctx)
  if ctx.block_id and is_ladybird(ctx.block_id) then
    remember_block(ctx.block_id)
    return ctx.block_id
  end
  local remembered = remembered_block()
  if remembered and is_ladybird(remembered) then return remembered end
  -- Prefer a pane this module launched (its label is exactly the configured one)
  -- over panes started by hand with a longer label.
  local blocks = ladybird_blocks()
  for _, block in ipairs(blocks) do
    if block.exact and is_ladybird(block.block_id) then
      remember_block(block.block_id)
      return block.block_id
    end
  end
  for index = #blocks, 1, -1 do
    if is_ladybird(blocks[index].block_id) then
      remember_block(blocks[index].block_id)
      return blocks[index].block_id
    end
  end
  return nil
end

local function send_open(block_id, url)
  if not url or url == "" then raise("no URL to open") end
  if url:find("\27", 1, true) then raise("refusing to send an escape character") end
  -- Arguments are not percent-encoded by the browser, so keep control characters out.
  url = url:gsub("[\r\n]", "")
  local payload = "\27_ladybird;open;" .. url .. "\27\\"
  local result, err = rex.block.call(TERMINAL_CREATOR, "write", { block_id = block_id, data = payload })
  if result == nil then raise("could not write to the Ladybird pane: " .. tostring(err)) end
  return url
end

-- A picker over history, with the current page preloaded and free text allowed
-- so an address that is not in history can still be typed.
local function pick_url(current, title)
  local items = history_items()
  if current then
    local known = false
    for _, item in ipairs(items) do
      if item.id == current then known = true break end
    end
    if not known then table.insert(items, 1, { id = current, title = current, subtitle = "current page", icon = "globe" }) end
  end
  local choice, why = rex.ui.pick{
    title = title or "Ladybird: open address",
    placeholder = "Filter history, or type an address or search",
    allow_other = true,
    items = items,
  }
  if choice == nil then
    if why ~= "cancelled" then raise("address picker: " .. tostring(why)) end
    return nil
  end
  return type(choice) == "table" and choice.id or choice
end


-- Declared here because the tab actions below call them.
local ladybird_command
local maybe_hide_status_line

-- Tabs are blocks, not layers: every tab is a Ladybird block living as a split in
-- one window, and the tab on show is the zoomed one, so the others keep running
-- behind it. Headless instances skip profile coordination, so every tab shares one
-- profile (one cookie jar) even though each is its own process.
local function read_tabs()
  local tabs = {}
  local file = io.open(TABS_FILE, "r")
  if not file then return tabs end
  for line in file:lines() do
    local block_id, port, url = line:match("^(%S+)\t(%d+)\t(.*)$")
    if block_id then
      tabs[#tabs + 1] = { block_id = block_id, port = tonumber(port), url = url }
    end
  end
  file:close()
  return tabs
end

-- Defined below, referenced above: declare them first so the lookups stay local.
local write_tabs
local locate_block

-- Recorded tabs whose block still exists in a window. Closing a pane leaves its
-- line behind, so the registry is read through here and rewritten when it shrank.
local function live_tabs(tabs)
  local live, dropped = {}, false
  for _, tab in ipairs(tabs) do
    if locate_block(tab.block_id) then
      live[#live + 1] = tab
    else
      dropped = true
    end
  end
  if dropped then write_tabs(live) end
  return live
end

function write_tabs(tabs)
  rex.exec({ "/bin/mkdir", "-p", STATE_DIR })
  local file = io.open(TABS_FILE, "w")
  if not file then return end
  for _, tab in ipairs(tabs) do
    file:write(table.concat({ tab.block_id, tostring(tab.port), tab.url or "" }, "\t"), "\n")
  end
  file:close()
end

local function port_is_busy(port)
  local result = rex.exec({ "/usr/bin/nc", "-z", "-G", "1", "127.0.0.1", tostring(port) })
  return result ~= nil and result.ok
end

local function next_free_port()
  local taken = {}
  for _, tab in ipairs(live_tabs(read_tabs())) do
    taken[tab.port] = true
  end
  for port = M.options.devtools_port, M.options.devtools_port + 49 do
    if not taken[port] and not port_is_busy(port) then return port end
  end
  raise("no free devtools port for a new tab")
end

function locate_block(block_id)
  local sessions = rex.call("session.list") or {}
  for _, session in ipairs(sessions.sessions or {}) do
    local view = rex.call("session.view", { session_id = session.session_id }) or {}
    for _, window in ipairs(view.windows or {}) do
      for _, layer in ipairs(window.layers or {}) do
        for _, block in ipairs(layer.blocks or {}) do
          if block.block_id == block_id then
            return { session_id = session.session_id, window_id = window.window_id }
          end
        end
      end
    end
  end
  return nil
end

local function tab_title(tab)
  local stdout = run({ M.options.ladyctl, "--port", tostring(tab.port), "tabs" })
  local title, url = (stdout or ""):match("^(.-) — (https?://%S+)")
  if title and title ~= "" then return title, url end
  return tab.url, tab.url
end

-- Bring a tab forward by zooming its block to fill the window; the other tabs stay
-- laid out behind it with their programs running.
function M.show_tab(ctx, block_id)
  local location = locate_block(block_id)
  if not location then raise("that tab is no longer in a window") end
  local result, err = rex.call("session.zoom_block", {
    session_id = location.session_id,
    block_id = block_id,
    zoom = true,
  })
  if not result then raise("could not show the tab: " .. tostring(err)) end
  remember_block(block_id)
  return location
end

function M.tab_new(ctx, url)
  if not url then url = pick_url(nil, "Ladybird: open in a new tab") end
  if not url then return { opened = false, reason = "cancelled" } end
  local anchor = target_block(ctx) or ctx.block_id
  if not anchor then raise("focus a Ladybird tab first, so the new one opens beside it") end

  local port = next_free_port()
  local pane, err = rex.session.new_split{
    anchor_id = anchor,
    direction = "horizontal",
    side = "after",
    ratio = 0.5,
    focus = true,
    layout = rex.layout.block{
      flavor = "com.superlogical.terminal.shell",
      label = M.options.label,
      options = { command = ladybird_command(url, port) },
    },
  }
  if not pane then raise("could not open a tab: " .. tostring(err)) end
  local block_id = pane.block_id or (pane.block_ids and pane.block_ids[1]) or pane.id
  if not block_id then raise("the new tab has no block") end

  local tabs = read_tabs()
  tabs[#tabs + 1] = { block_id = block_id, port = port, url = url }
  write_tabs(tabs)
  remember_block(block_id)
  remember_port(port)
  maybe_hide_status_line(block_id)
  M.show_tab(ctx, block_id)
  return { opened = true, block_id = block_id, port = port, url = url }
end

local function pick_tab(title, placeholder)
  local tabs = live_tabs(read_tabs())
  if #tabs == 0 then raise("no Ladybird tabs are recorded") end
  local items = {}
  for _, tab in ipairs(tabs) do
    local text, url = tab_title(tab)
    items[#items + 1] = {
      id = tab.block_id,
      title = text or url or "Ladybird",
      subtitle = url or tab.url,
      icon = "globe",
    }
  end
  local choice, why = rex.ui.pick{ title = title, placeholder = placeholder, items = items }
  if choice == nil then
    if why ~= "cancelled" then raise("tab picker: " .. tostring(why)) end
    return nil
  end
  return type(choice) == "table" and choice.id or choice
end

function M.tabs(ctx)
  local block_id = pick_tab("Ladybird: switch tab", "Filter open pages")
  if not block_id then return { switched = false, reason = "cancelled" } end
  M.show_tab(ctx, block_id)
  return { switched = true, block_id = block_id }
end

function M.tab_close(ctx)
  local block_id = pick_tab("Ladybird: close tab", "Filter open pages")
  if not block_id then return { closed = false, reason = "cancelled" } end
  local location = locate_block(block_id)
  if not location then raise("that tab is no longer in a window") end
  rex.call("block.close", { session_id = location.session_id, block_id = block_id })
  local keep = {}
  for _, tab in ipairs(read_tabs()) do
    if tab.block_id ~= block_id then keep[#keep + 1] = tab end
  end
  write_tabs(keep)
  return { closed = true, block_id = block_id }
end

-- Ask a freshly started pane to give up its status line, when the build supports it.
function maybe_hide_status_line(block_id)
  if not M.options.hide_status_line or not block_id then return end
  rex.block.call(TERMINAL_CREATOR, "write", { block_id = block_id, data = "\27_ladybird;chrome;off\27\\" })
end

function ladybird_command(url, port)
  -- Fail here rather than in a pane that dies on its first frame: a missing
  -- terminal-mode build is the most likely first-run problem.
  if not executable(M.options.binary) then
    raise("no usable Ladybird binary at " .. tostring(M.options.binary)
      .. "; set LADYBIRD_BINARY or the binary option to a --headless=terminal build")
  end
  return {
    M.options.binary,
    "--headless=terminal",
    "--device-pixel-ratio=" .. tostring(M.options.device_pixel_ratio),
    "--profile-path=" .. M.options.profile,
    "--devtools=" .. tostring(port or M.options.devtools_port),
    url,
  }
end

function M.open(ctx, url)
  local block_id = target_block(ctx)
  if not block_id then
    return M.launch(ctx, url)
  end
  if not url then url = pick_url(current_url(block_id)) end
  if not url then return { opened = false, reason = "cancelled" } end
  return { opened = true, block_id = block_id, url = send_open(block_id, url) }
end

function M.launch(ctx, url)
  if not url then url = pick_url(nil, "Ladybird: open in a new pane") end
  if not url then return { opened = false, reason = "cancelled" } end
  -- Its own DevTools port and its own line in the registry: a pane opened here is
  -- a tab too, so the picker lists it and two panes never fight over one port.
  local port = next_free_port()
  local pane, err = rex.session.new_split{
    anchor_id = ctx.block_id,
    direction = "horizontal",
    side = "after",
    ratio = 0.60,
    focus = true,
    layout = rex.layout.block{
      flavor = "com.superlogical.terminal.shell",
      label = M.options.label,
      options = { command = ladybird_command(url, port) },
    },
  }
  if not pane then raise("could not open a Ladybird pane: " .. tostring(err)) end
  local block_id = pane.block_id or (pane.block_ids and pane.block_ids[1]) or pane.id
  if not block_id then raise("the new pane has no block") end

  local tabs = read_tabs()
  tabs[#tabs + 1] = { block_id = block_id, port = port, url = url }
  write_tabs(tabs)
  remember_block(block_id)
  remember_port(port)
  maybe_hide_status_line(block_id)
  return { opened = true, block_id = block_id, port = port, url = url }
end

function M.url(ctx)
  local block_id = target_block(ctx)
  if not block_id then raise("no Ladybird pane is open") end
  local metadata = devtools_metadata()
  if metadata then
    return { block_id = block_id, url = metadata.url, title = metadata.title, source = "devtools" }
  end
  local url = current_url(block_id)
  if not url then raise("could not read the address from the Ladybird status line") end
  return { block_id = block_id, url = url, source = "status-line" }
end

-- Links on the page, through the DevTools server, as a picker.
function M.links(ctx)
  local block_id = target_block(ctx)
  if not block_id then raise("no Ladybird pane is open") end
  local stdout = run({ M.options.ladyctl, "links", "--limit", "300" })
  if not stdout then raise("ladyctl could not list links (is --devtools running?)") end
  local items, seen = {}, {}
  for line in stdout:gmatch("[^\n]+") do
    local text, href = line:match("^(.-) — (https?://%S+)$")
    -- Pickers require unique ids, and a page links to the same address many times.
    if href and not seen[href] then
      seen[href] = true
      items[#items + 1] = { id = href, title = text ~= "" and text or href, subtitle = href, icon = "globe" }
    end
  end
  if #items == 0 then return { opened = false, reason = "no_links" } end
  local choice, why = rex.ui.pick{
    title = "Ladybird: open a link on this page",
    placeholder = "Filter links",
    items = items,
  }
  if choice == nil then
    if why ~= "cancelled" then raise("link picker: " .. tostring(why)) end
    return { opened = false, reason = "cancelled" }
  end
  local href = type(choice) == "table" and choice.id or choice
  send_open(block_id, href)
  return { opened = true, block_id = block_id, url = href }
end

-- The controls the page offers, as a picker; the choice is clicked through
-- ladyctl, so the click carries the pointer events a menu or a drag target
-- listens for. A ref that the page has moved out from under us is a failure,
-- not a click on whatever took its place.
function M.click_control(ctx)
  local block_id = target_block(ctx)
  if not block_id then raise("no Ladybird pane is open") end
  local stdout, err = run({ M.options.ladyctl, "snapshot", "--list" })
  if not stdout then raise("ladyctl could not read the page: " .. tostring(err)) end
  local items = {}
  for line in stdout:gmatch("[^\n]+") do
    local ref, kind, rest = line:match("^(e%d+)\t([^\t]+)\t(.*)$")
    if ref then
      -- Tab-separated: a label can hold a comma or an em dash, but not a tab.
      local label, flags = rest:match("^(.-)\t(.*)$")
      if label == nil then label, flags = rest, nil end
      items[#items + 1] = {
        id = ref,
        title = label ~= "" and label or "(" .. kind .. ")",
        subtitle = kind .. (flags and (" [" .. flags .. "]") or ""),
        icon = "globe",
      }
    end
  end
  if #items == 0 then return { clicked = false, reason = "no_controls" } end
  local choice, why = rex.ui.pick{
    title = "Ladybird: click a control on this page",
    placeholder = "Filter controls",
    items = items,
  }
  if choice == nil then
    if why ~= "cancelled" then raise("control picker: " .. tostring(why)) end
    return { clicked = false, reason = "cancelled" }
  end
  local ref = type(choice) == "table" and choice.id or choice
  local clicked, click_err = run({ M.options.ladyctl, "click", ref })
  if not clicked then raise("could not click " .. tostring(ref) .. ": " .. tostring(click_err)) end
  return { clicked = true, block_id = block_id, ref = ref }
end

-- The command that copies standard input to the clipboard on this machine, or
-- nil when none of them is installed.
local function clipboard_reads_stdin()
  local path = on_path("pbcopy")
  if path then return path end
  path = on_path("wl-copy")
  if path then return path end
  path = on_path("xclip")
  if path then return path .. " -selection clipboard" end
  path = on_path("xsel")
  if path then return path .. " --clipboard --input" end
end

function M.copy_url(ctx)
  local result = M.url(ctx)
  local path = os.tmpname()
  local file = assert(io.open(path, "w"))
  file:write(result.url)
  file:close()
  local clipboard = clipboard_reads_stdin()
  if clipboard == nil then
    os.remove(path)
    raise("no clipboard tool: install pbcopy (macOS), wl-copy (Wayland) or xclip/xsel (X11)")
  end
  local copied = rex.exec({ "/bin/sh", "-c", clipboard .. " < '" .. path .. "'" })
  os.remove(path)
  if copied == nil or not copied.ok then raise("could not copy the address") end
  return result
end

function M.setup(opts)
  for name, value in pairs(opts or {}) do
    if M.options[name] == nil then raise("unknown rex-ladybird option: " .. name) end
    M.options[name] = value
  end

  local function register(name, title, description, category, handler, args)
    rex.action{
      name = name,
      title = title,
      description = description,
      category = category,
      keywords = "ladybird browser web page url",
      args = args,
      run = handler,
    }
  end

  local url_arg = { url = "string?" }

  register("ladybird_open", "Ladybird: open address…",
    "Pick from history or type an address, and load it in the Ladybird terminal pane.",
    "Browser", function(ctx, args) return M.open(ctx, args and args.url) end, url_arg)

  register("ladybird_new", "Ladybird: new pane…",
    "Open a Ladybird terminal pane beside this one, at the picked address.",
    "Browser", function(ctx, args) return M.launch(ctx, args and args.url) end, url_arg)

  register("ladybird_links", "Ladybird: open a link on this page…",
    "Pick a link from the page as the DevTools server reports it, and load it in the pane.",
    "Browser", function(ctx) return M.links(ctx) end)

  register("ladybird_click", "Ladybird: click a control on this page…",
    "Pick a control the page offers -- a link, a button, a field -- and click it.",
    "Browser", function(ctx) return M.click_control(ctx) end)

  register("ladybird_tab_new", "Ladybird: new tab…",
    "Open the picked address in a new tab: a full-window floating layer in this window.",
    "Browser", function(ctx, args) return M.tab_new(ctx, args and args.url) end, url_arg)

  register("ladybird_tabs", "Ladybird: switch tab…",
    "List the open Ladybird tabs and bring the picked one to the front.",
    "Browser", function(ctx) return M.tabs(ctx) end)

  register("ladybird_tab_close", "Ladybird: close tab…",
    "Close a tab and the block running it.",
    "Browser", function(ctx) return M.tab_close(ctx) end)

  register("ladybird_url", "Ladybird: copy current address",
    "Read the address from the Ladybird status line and put it on the clipboard.",
    "Browser", function(ctx) return M.copy_url(ctx) end)

  return M
end

return M
