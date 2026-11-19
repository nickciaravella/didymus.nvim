local M = {}

M.defaults = {
  agent = {
    cmd = "claude",
    view = "split", -- "split" or "float"
    backend = "terminal", -- "terminal" or "test"
    split = { width = 0.4 },
    float = { width = 0.85, height = 0.85 },
    keys = { focus = false, leave = false }, -- for example "<C-a>"
    input = {
      width = 60,
      max_height = 10,
      keys = { send = "<C-s>", append = "<C-y>", cancel = "q" },
    },
    terminal = { ready_delay = 500, submit_delay = 50 }, -- milliseconds
  },
  review = {
    picker = "snacks", -- "snacks", "test" or an adapter table. See lua/didymus/ui/picker/.
    -- The options of each kind of list, for each adapter. For example:
    -- { changes = { snacks = { layout = { preset = "ivy" } } } }
    picker_config = {},
    provider = "github", -- "github", "test" or a provider table. See lua/didymus/review/provider/.
    icons = { active = "💬", resolved = "✅" }, -- The state of a thread. "" shows no icon.
    -- In the files panel. False turns off a key. `comment` adds a comment on the file of the row.
    panel = { keys = { toggle_active = "a", refresh = "R", comment = "c" } },
    input = {
      width = 60,
      max_height = 10,
      -- Also for a reply. A submit has only `post`. `suggest` adds a suggestion to a comment.
      keys = { post = "<C-s>", add = "<C-y>", suggest = "<M-s>", cancel = "q" },
    },
    thread = {
      -- In the thread float of a thread that shows only in the panel. False turns a key off.
      keys = { reply = "r", resolve = "x" },
    },
  },
  diff = {
    provider = "gitsigns", -- "gitsigns", "test" or a provider table. See lua/didymus/diff/provider/.
    enabled = true, -- The diff shows when a review opens.
    layout = "inline", -- "inline" or "split"
    sides = "both", -- "both" or "head". Only `:Didymus diff side base` shows the base side.
    split = { width = 0.5 }, -- The width of the base window. Below 1, a fraction of the code window.
  },
}

M.options = vim.deepcopy(M.defaults)

---@param opts table?
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
