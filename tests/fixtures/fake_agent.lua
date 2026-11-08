-- A fake agent CLI for tests. Run it with `nvim --clean -l tests/fixtures/fake_agent.lua`.
--
-- It reads the input in raw mode with bracketed paste, and shows one row for each event:
--   paste: "<text>"      a bracketed paste
--   key: "<byte>"        a key outside a paste
--   submitted: "<text>"  a "\r" or "\n" outside a paste, with all the input since the last submit
--
-- Arguments:
--   --name <name>  Show <name> in the banner.
--   --exit <code>  Exit with <code> after the first submit.

local name, exit_code = "agent", nil
for i = 1, #arg do
  if arg[i] == "--name" then
    name = arg[i + 1]
  elseif arg[i] == "--exit" then
    exit_code = tonumber(arg[i + 1])
  end
end

local paste_start, paste_end = "\27[200~", "\27[201~"
local prompt = "> "

---@param text string
local function write(text)
  io.write(text)
  io.stdout:flush()
end

--- Replace the prompt with `event`, then show the prompt on the next row.
---@param event string
local function show(event)
  write("\r\27[K" .. event .. "\r\n" .. prompt)
end

local pending, input, in_paste = "", "", false

local function parse()
  while pending ~= "" do
    if in_paste then
      local i = pending:find(paste_end, 1, true)
      if not i then
        return
      end
      local text = pending:sub(1, i - 1)
      pending, in_paste = pending:sub(i + #paste_end), false
      input = input .. text
      show("paste: " .. vim.inspect(text))
    elseif vim.startswith(pending, paste_start) then
      pending, in_paste = pending:sub(#paste_start + 1), true
    elseif vim.startswith(paste_start, pending) then
      -- The rest of the paste start comes in the next read.
      return
    else
      local key = pending:sub(1, 1)
      pending = pending:sub(2)
      -- A raw "\n" also submits, so that a test fails if a newline is not in a paste.
      if key == "\r" or key == "\n" then
        show("submitted: " .. vim.inspect(input))
        input = ""
        if exit_code then
          os.exit(exit_code)
        end
      else
        input = input .. key
        show("key: " .. vim.inspect(key))
      end
    end
  end
end

-- Set the modes before the first output, because didymus sends input after the first output.
local stdin = assert(vim.uv.new_tty(0, true))
stdin:set_mode("raw")
write("\27[?2004h")
write(("fake agent %s\r\n%s"):format(name, prompt))

local done = false
stdin:read_start(function(err, data)
  if err or not data then
    done = true
    return
  end
  pending = pending .. data
  parse()
end)

vim.wait(24 * 60 * 60 * 1000, function()
  return done
end)
