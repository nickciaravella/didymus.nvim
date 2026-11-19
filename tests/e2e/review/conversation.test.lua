local helpers = dofile("tests/e2e/review/helpers.lua")
local wait_for = dofile("tests/helpers.lua").wait_for

local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.cmd("runtime plugin/didymus.lua")
      child.lua("require('didymus').setup({ review = { picker = 'test', provider = 'test' } })")
      -- The git config of the user can change the output of git.
      child.lua("vim.env.GIT_CONFIG_GLOBAL, vim.env.GIT_CONFIG_NOSYSTEM = '/dev/null', '1'")
    end,
    post_once = child.stop,
  },
})

local picker = "require('didymus.ui.picker.test')"

--- Give the general comments of the change "1" to the test provider.
---@param comments didymus.review.Comment[]
local function set_comments(comments)
  child.lua("require('didymus.review.provider.test').comments['1'] = ...", { comments })
end

--- Wait until the open review has `count` general comments.
---@param count integer
local function wait_for_comments(count)
  wait_for(function()
    return child.lua_get("#require('didymus.review').current().comments") == count
  end, ("%d comments"):format(count))
end

--- Open the review of a change with two general comments, and wait for them.
local function open_review()
  local repo = helpers.make_repo()
  child.fn.chdir(repo.dir)
  helpers.set_changes(child, { repo.change })
  set_comments({
    { author = "octocat", body = "\nThanks for the change.\nMore text.", pending = false },
    { author = "hubot", body = "LGTM", pending = false },
  })
  child.cmd("Didymus review open 1")
  helpers.wait_for_review(child, "1")
  wait_for_comments(2)
end

--- The items of the panel after the files: the conversation rows.
---@return didymus.picker.Item[]
local function conversation_items()
  local items = helpers.picker_calls(child, "panel")[1].items
  for index, item in ipairs(items) do
    if item.value.kind == "conversation" then
      return vim.list_slice(items, index)
    end
  end
  error("no conversation row")
end

---@return integer?
local function float_win()
  for _, win in ipairs(child.api.nvim_tabpage_list_wins(0)) do
    if child.api.nvim_win_get_config(win).relative ~= "" then
      return win
    end
  end
end

--- The title, the footer and the lines of the float.
---@return { title: string, footer: string?, lines: string[] }
local function float_content()
  local win
  wait_for(function()
    win = float_win()
    return win ~= nil
  end, "a float")
  local config = child.api.nvim_win_get_config(win)
  return {
    title = config.title[1][1],
    footer = config.footer and config.footer[1][1],
    lines = child.api.nvim_buf_get_lines(child.api.nvim_win_get_buf(win), 0, -1, true),
  }
end

---@param text string
local function wait_for_message(text)
  wait_for(function()
    return child.cmd_capture("messages"):find(text, 1, true) ~= nil
  end, function()
    return ("%q is not in the messages:\n%s"):format(text, child.cmd_capture("messages"))
  end)
end

T["the panel shows the general comments after the files, with the body in the preview"] = function()
  open_review()
  local items = conversation_items()
  eq(
    vim.tbl_map(function(item)
      return { item.depth or 0, item.text }
    end, items),
    {
      { 0, "Conversation 2 comments" },
      { 1, "@octocat Thanks for the change." },
      { 1, "@hubot LGTM" },
    }
  )
  eq(items[1].segments, { { "Conversation", "Title" }, { " 2 comments", "Comment" } })
  eq(items[2].segments, { { "@octocat", "DidymusThread" }, { " Thanks for the change." } })
  eq(items[3].preview, { lines = { "**@hubot**", "", "LGTM" }, filetype = "markdown" })
end

T["with no general comments, the conversation row has no count"] = function()
  set_comments({})
  local repo = helpers.make_repo()
  child.fn.chdir(repo.dir)
  helpers.set_changes(child, { repo.change })
  child.cmd("Didymus review open 1")
  helpers.wait_for_review(child, "1")
  child.lua("vim.wait(50)")
  eq(
    vim.tbl_map(function(item)
      return item.text
    end, conversation_items()),
    { "Conversation" }
  )
end

T["<CR> on a conversation row opens all general comments in a float"] = function()
  open_review()
  local win = child.api.nvim_get_current_win()
  child.lua(picker .. ".choose('@hubot LGTM')")
  eq(child.api.nvim_get_current_win(), win)
  eq(float_content(), {
    title = " Conversation of #1 ",
    -- The float of `open_floating_preview()` draws the line between the comments.
    lines = {
      "**@octocat**",
      "",
      "Thanks for the change.",
      "More text.",
      "──────────────────────",
      "**@hubot**",
      "",
      "LGTM",
    },
  })
end

T["comment change posts a general comment at once"] = function()
  open_review()
  child.cmd("Didymus review comment change")
  -- A general comment is not in a review, so the float cannot add it to the review.
  eq(float_content(), {
    title = " Comment on #1 ",
    footer = " <C-s> comment now  q cancel ",
    lines = { "" },
  })
  child.type_keys("Nice work.", "<C-s>")
  wait_for_comments(3)
  eq(
    child.lua_get("require('didymus.review.provider.test').comments['1'][3]"),
    { author = "reviewer", body = "Nice work.", pending = false }
  )
  eq(conversation_items()[1].text, "Conversation 3 comments")
  eq(conversation_items()[4].text, "@reviewer Nice work.")
  wait_for_message("didymus: posted a comment on #1")
end

T["c on a conversation row opens the float of a general comment"] = function()
  open_review()
  child.lua(picker .. ".press('c', 'Conversation 2 comments')")
  eq(float_content().title, " Comment on #1 ")
  child.type_keys("<Esc>", "q")
  child.lua(picker .. ".press('c', '@hubot LGTM')")
  eq(float_content().title, " Comment on #1 ")
end

T["after an error, the next general comment starts with the text"] = function()
  open_review()
  child.lua("require('didymus.review.provider.test').errors.post_change_comment = 'no network'")
  child.cmd("Didymus review comment change")
  float_content()
  child.type_keys("First try.")
  -- `type_keys()` gives the error message as an error of the test.
  child.api.nvim_input("<C-s>")
  wait_for_message(
    "didymus: cannot post the comment on #1: no network. "
      .. "The next comment on #1 starts with its text."
  )
  eq(child.lua_get("#require('didymus.review').current().comments"), 2)
  child.cmd("Didymus review comment change")
  eq(float_content().lines, { "First try." })
end

T["a refresh gets the general comments again"] = function()
  open_review()
  set_comments({ { author = "octocat", body = "New.", pending = false } })
  child.cmd("Didymus review refresh")
  wait_for_comments(1)
  eq(conversation_items()[2].text, "@octocat New.")
end

T["an error of the comments at the open shows, and the threads still show"] = function()
  local repo = helpers.make_repo()
  child.fn.chdir(repo.dir)
  helpers.set_changes(child, { repo.change })
  helpers.set_threads(child, "1", { helpers.make_thread("1", "file.txt") })
  child.lua("require('didymus.review.provider.test').errors.get_comments = 'no network'")
  child.lua("require('didymus.review').open({ id = '1' })")
  helpers.wait_for_review(child, "1")
  helpers.wait_for_threads(child, 1)
  wait_for_message("didymus: cannot get the comments of #1: no network")
end

return T
