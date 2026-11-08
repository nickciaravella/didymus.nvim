local M = {}

---@param cmd string|string[]
---@return string?
local function get_program(cmd)
  if type(cmd) == "table" then
    return cmd[1]
  end
  return vim.split(vim.trim(cmd), "%s+")[1]
end

local function check_agent()
  vim.health.start("didymus agent")

  local program = get_program(require("didymus.config").options.agent.cmd)
  if not program or program == "" then
    vim.health.warn("`agent.cmd` is empty", "Set `agent.cmd`.")
  elseif vim.fn.executable(program) == 1 then
    vim.health.ok(("`%s` is on $PATH (agent.cmd)"):format(program))
  else
    vim.health.warn(
      ("`%s` is not on $PATH (agent.cmd)"):format(program),
      "Install it, or set `agent.cmd`."
    )
  end
end

function M.check()
  vim.health.start("didymus")

  if vim.fn.has("nvim-0.12") == 1 then
    local version = vim.version()
    vim.health.ok(("Neovim %d.%d.%d"):format(version.major, version.minor, version.patch))
  else
    vim.health.error("Neovim 0.12 or later is necessary")
  end

  if vim.fn.executable("git") == 1 then
    vim.health.ok("`git` is available")
  else
    vim.health.error("`git` is not on $PATH")
  end

  check_agent()
end

return M
