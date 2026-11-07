-- A fake agent CLI for tests. Run it with `nvim --clean -l tests/fixtures/fake_agent.lua`.
--
-- Arguments:
--   --name <name>  Show <name> in the banner.
--   --exit <code>  Exit with <code> after the first line of input.

local name, exit_code = "agent", nil
for i = 1, #arg do
  if arg[i] == "--name" then
    name = arg[i + 1]
  elseif arg[i] == "--exit" then
    exit_code = tonumber(arg[i + 1])
  end
end

io.write(("fake agent %s\r\n"):format(name))
io.stdout:flush()

if exit_code then
  io.read("l")
  os.exit(exit_code)
end

-- Wait until stdin closes.
while io.read(1) do
end
