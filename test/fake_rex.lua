-- An in-memory stand-in for the `rex` global: sessions, blocks, the terminal's
-- status line and the pickers, with every call recorded in order so tests can
-- check what the module asked Rex to do.
--
--   local fake = require("fake_rex").install()
--   fake:reset()
--
-- HOME and XDG_STATE_HOME point inside a temporary directory, so the module's
-- registry files are real files that a test can read back.

local Fake = {}
Fake.__index = Fake

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function temp_dir()
  local base = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
  local seed = tostring(os.time()):sub(-6) .. tostring(math.random(1, 1e6))
  local dir = base .. "/rex-ext-test." .. seed
  os.execute("mkdir -p " .. shell_quote(dir .. "/home/state") .. " " .. shell_quote(dir .. "/home/data"))
  return dir
end

-- Put the fake in place of the rex global and of the environment the module
-- reads at load time. Returns the fake.
function Fake.install()
  local fake = setmetatable({ tmp = temp_dir() }, Fake)
  fake.env = {
    HOME = fake.tmp .. "/home",
    XDG_STATE_HOME = fake.tmp .. "/home/state",
  }

  local getenv = os.getenv
  os.getenv = function(name)
    if fake.env[name] ~= nil then return fake.env[name] or nil end
    return getenv(name)
  end

  rex = fake:api()
  fake:reset()
  return fake
end

function Fake:reset()
  self.sessions = {}   -- { session_id, windows = { { window_id, layers = { { blocks = { ... } } } } } }
  self.status = {}     -- [block_id] = status line text
  self.process = {}    -- [block_id] = { foreground = { argv0 = ... } }
  self.exec_handlers = {} -- [args joined by space] = function(argv) -> result
  self.calls = {}      -- every call, in order: { tool = "exec"|"call"|"block"|"pick"|"split", ... }
  self.actions = {}    -- [name] = the table given to rex.action
  self.pick_answers = {} -- queued { value, reason } replies to rex.ui.pick
  self.split_result = nil -- what rex.session.new_split returns
  self.busy_ports = {} -- ports nc -z reports as open
end

-- Every recorded call of one tool, in order.
function Fake:calls_of(tool)
  local out = {}
  for _, call in ipairs(self.calls) do
    if call.tool == tool then out[#out + 1] = call end
  end
  return out
end

function Fake:last_call(tool)
  local calls = self:calls_of(tool)
  return calls[#calls]
end

-- Add a session holding one window with one layer of blocks.
function Fake:add_session(blocks)
  local session = {
    session_id = "session:" .. (#self.sessions + 1),
    windows = { {
      window_id = "window:" .. (#self.sessions + 1),
      layers = { { blocks = blocks or {} } },
    } },
  }
  self.sessions[#self.sessions + 1] = session
  return session
end

-- A block as session.view reports it.
function Fake:add_block(session, block_id, label, creator_name)
  session.windows[1].layers[1].blocks[#session.windows[1].layers[1].blocks + 1] = {
    block_id = block_id,
    label = label or "Ladybird",
    creator_name = creator_name or "com.superlogical.terminal",
  }
end

function Fake:remove_block(block_id)
  for _, session in ipairs(self.sessions) do
    for _, window in ipairs(session.windows) do
      for _, layer in ipairs(window.layers) do
        for index = #layer.blocks, 1, -1 do
          if layer.blocks[index].block_id == block_id then table.remove(layer.blocks, index) end
        end
      end
    end
  end
end

-- Answer `rex.exec` for argv[1] starting with `prefix`, with `result`.
function Fake:on_exec(prefix, result)
  self.exec_handlers[prefix] = result
end

-- The status line the terminal reports for a block.
function Fake:set_status(block_id, text)
  self.status[block_id] = text
end

function Fake:set_process(block_id, argv0)
  self.process[block_id] = { foreground = { argv0 = argv0 } }
end

function Fake:api()
  local fake = self
  local function record(tool, payload)
    payload.tool = tool
    fake.calls[#fake.calls + 1] = payload
    return payload
  end

  return {
    exec = function(argv, options)
      record("exec", { argv = argv, options = options })
      local joined = table.concat(argv, " ")
      -- Longest prefix wins, so "nc -z -G 1" can be answered separately.
      local best, handler
      for prefix, result in pairs(fake.exec_handlers) do
        if joined:sub(1, #prefix) == prefix and (best == nil or #prefix > #best) then
          best, handler = prefix, result
        end
      end
      if handler ~= nil then
        if type(handler) == "function" then return handler(argv) end
        return handler
      end
      if argv[1] == "/bin/mkdir" then
        -- Creating a directory is the one side effect worth reproducing.
        os.execute("mkdir -p " .. shell_quote(argv[#argv]))
        return { ok = true, stdout = "" }
      end
      if argv[1] == "/usr/bin/nc" then
        local port = tonumber(argv[#argv])
        if fake.busy_ports[port] then return { ok = true } end
        return { ok = false, stderr = "connect failed" }
      end
      return { ok = false, stderr = "not found" }
    end,

    call = function(method, params)
      record("call", { method = method, params = params })
      if method == "session.list" then
        local sessions = {}
        for _, session in ipairs(fake.sessions) do
          sessions[#sessions + 1] = { session_id = session.session_id }
        end
        return { sessions = sessions }
      elseif method == "session.view" then
        for _, session in ipairs(fake.sessions) do
          if session.session_id == (params or {}).session_id then
            return { windows = session.windows }
          end
        end
        return { windows = {} }
      elseif method == "session.zoom_block" then
        return { ok = true }
      elseif method == "block.close" then
        fake:remove_block((params or {}).block_id)
        return { ok = true }
      end
      return nil
    end,

    block = {
      call = function(creator, method, params)
        record("block", { creator = creator, method = method, params = params })
        local block_id = (params or {}).block_id
        if method == "format" then
          local text = fake.status[block_id]
          if text == nil then return nil end
          return { content = text }
        elseif method == "process" then
          return fake.process[block_id]
        elseif method == "write" then
          return { ok = true }
        elseif method == "set_theme" then
          return { ok = true, theme = (params or {}).background }
        end
        return nil
      end,
    },

    ui = {
      pick = function(spec)
        record("pick", { spec = spec })
        local answer = table.remove(fake.pick_answers, 1) or { value = nil, reason = "cancelled" }
        return answer.value, answer.reason
      end,
      input = function(spec)
        record("input", { spec = spec })
        return nil, "cancelled"
      end,
    },

    session = {
      new_split = function(spec)
        record("split", { spec = spec })
        return fake.split_result
      end,
    },

    layout = {
      block = function(spec)
        record("layout", { spec = spec })
        spec.block = true
        return spec
      end,
    },

    action = function(spec)
      fake.actions[spec.name] = spec
      return spec
    end,

    bind = function() end,

    log = function(message)
      record("log", { message = message })
    end,
  }
end

return Fake
