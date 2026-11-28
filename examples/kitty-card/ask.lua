-- Open the card pane as a question an agent can wait on, in place of a palette modal:
--   rex do examples/kitty-card/ask.lua --action ask \
--     question='Which platforms?' choices='both=Mac + iOS|mac=Mac only' --json
-- The answer lands in the file the action returns; the block's label shows it too.
local HOME = os.getenv("HOME")
local HERE = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):match("^(.*)/[^/]*$")

local function script(name) return HERE .. "/" .. name end

rex.action{
  name = "ask",
  title = "Ask in a card",
  description = "Open a question card in a new tab; the answer is written to a file.",
  category = "Ask",
  args = { question = "string", choices = "string?", answer = "string?" },
  run = function(ctx, args)
    local choices = args.choices or "yes=Yes|no=No"
    local id = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
    local answer_file = args.answer or (HOME .. "/.local/state/rex-card/" .. id .. ".json")
    rex.exec({ "/bin/mkdir", "-p", (answer_file:match("^(.*)/[^/]*$")) })
    local created = rex.session.new_window{
      session_id = ctx and ctx.session_id,
      window_label = "Ask: " .. args.question:sub(1, 40),
      focus = false,
      layout = rex.layout.block{
        flavor = "com.superlogical.terminal.shell",
        label = "Ask",
        options = {
          -- `shell = "none"` silently ignored `command` on this Rex version and started a
          -- login shell instead; running through the user's shell also finds their PATH.
          command = { "/usr/bin/env",
            "CARD_QUESTION=" .. args.question,
            "CARD_CHOICES=" .. choices,
            "CARD_ANSWER=" .. answer_file,
            "python3", script("card.py") },
        },
      },
    }
    if created == nil then error("could not open the card pane", 0) end
    return {
      answer_file = answer_file,
      window_id = created.window_id,
      block_id = created.block_ids and created.block_ids[1],
      hint = "read the file once it appears; the pane's label shows the answer too",
    }
  end,
}
