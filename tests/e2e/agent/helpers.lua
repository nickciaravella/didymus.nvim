-- Helpers for the agent end-to-end tests. Load them with `dofile()`.

local M = {}

local fake_agent = vim.fn.fnamemodify("tests/fixtures/fake_agent.lua", ":p")

---@param ... string Arguments for the fake agent.
---@return string[]
function M.fake_cmd(...)
  return { vim.v.progpath, "--clean", "-l", fake_agent, ... }
end

---@param check fun(): boolean
---@param what string
function M.wait_for(check, what)
  for _ = 1, 500 do
    if check() then
      return
    end
    vim.uv.sleep(10)
  end
  error("timeout: " .. what)
end

---@param child MiniTest.child
---@return integer?
function M.agent_buf(child)
  return child.lua_get([[
    (function()
      local session = require("didymus.agent").current()
      return session and session.backend and session.backend:buf()
    end)()
  ]])
end

---@param child MiniTest.child
---@return string[]
function M.agent_lines(child)
  local buf = M.agent_buf(child)
  return buf and child.api.nvim_buf_get_lines(buf, 0, -1, false) or {}
end

---@param child MiniTest.child
---@param text string
function M.wait_for_text(child, text)
  M.wait_for(function()
    return table.concat(M.agent_lines(child), "\n"):find(text, 1, true) ~= nil
  end, text)
end

return M
