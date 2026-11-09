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

local function check_review()
  vim.health.start("didymus review")
  local options = require("didymus.config").options.review

  local adapter, picker_err = require("didymus.ui.picker").get(options.picker)
  if adapter then
    adapter.health()
  else
    vim.health.error(("%s (review.picker)"):format(picker_err), "Set `review.picker`.")
  end

  local provider, provider_err = require("didymus.review.provider").get(options.provider)
  if provider then
    provider.health()
  else
    vim.health.error(("%s (review.provider)"):format(provider_err), "Set `review.provider`.")
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
  check_review()
end

return M
