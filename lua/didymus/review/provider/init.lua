--- The review types and the provider interface. A provider changes the data of a code host
--- into these types. See docs/architecture/review.md#provider-interface.

---@alias didymus.review.Side "head"|"base"

--- Lines, 1-based. The range includes `first` and `last`.
---@class didymus.review.Range
---@field first integer
---@field last integer

---@class didymus.review.ChangeSummary
---@field id string The id on the code host, such as the PR number. `get_change()` takes it.
---@field title string
---@field author string
---@field body string Markdown.
---@field is_draft boolean

--- A provider can add its own fields, such as a node id. The review session gives the same
--- table back to the provider.
---@class didymus.review.Change: didymus.review.ChangeSummary
---@field base_branch string
---@field head_branch string
---@field base_sha string
---@field head_sha string
---@field files didymus.review.ChangedFile[]
---@field pending_review_id string? The pending review of the user, if there is one.

---@class didymus.review.ChangedFile
---@field path string
---@field status "added"|"modified"|"deleted"|"renamed"
---@field additions integer
---@field deletions integer
---@field patch string? The hunks of the unified diff, with no file header. Nil for a large or binary file, or a pure rename.

---@class didymus.review.Thread
---@field id string
---@field path string
---@field side didymus.review.Side
---@field range didymus.review.Range? Nil if the thread is outdated or on the file.
---@field resolved boolean
---@field outdated boolean
---@field comments didymus.review.Comment[]

---@class didymus.review.Comment
---@field author string
---@field body string Markdown.
---@field pending boolean

--- A new comment on the head side.
---@class didymus.review.CommentDraft
---@field path string
---@field range didymus.review.Range
---@field body string

--- All methods are async. Each one calls `cb` later, and does not block the UI.
---@class didymus.review.Provider
---@field list_changes fun(self, opts: { search: string? }, cb: fun(err: string?, changes: didymus.review.ChangeSummary[]?))
---@field get_change fun(self, id: string, cb: fun(err: string?, change: didymus.review.Change?)) Files, patches and the pending review.
---@field checkout fun(self, change: didymus.review.Change, cb: fun(err: string?)) Make the change head the current checkout.
---@field get_threads fun(self, change: didymus.review.Change, cb: fun(err: string?, threads: didymus.review.Thread[]?))
---@field add_comment fun(self, change: didymus.review.Change, draft: didymus.review.CommentDraft, cb: fun(err: string?, thread: didymus.review.Thread?)) Start a pending review if there is none.
---@field reply fun(self, change: didymus.review.Change, thread_id: string, body: string, cb: fun(err: string?))
---@field set_resolved fun(self, change: didymus.review.Change, thread_id: string, resolved: boolean, cb: fun(err: string?))
---@field submit_review fun(self, change: didymus.review.Change, verdict: "approve"|"comment"|"request_changes", body: string?, cb: fun(err: string?))
---@field discard_review fun(self, change: didymus.review.Change, cb: fun(err: string?))
---@field health fun() Report the dependencies with `vim.health`.

local M = {}

local builtin = {
  github = "didymus.review.provider.github",
  test = "didymus.review.provider.test",
}

--- The provider of `spec`: the name of a built-in provider, or a provider table.
---@param spec string|didymus.review.Provider
---@return didymus.review.Provider? provider
---@return string? err
function M.get(spec)
  if type(spec) == "table" then
    return spec
  end
  local module = builtin[spec]
  if not module then
    return nil,
      ('unknown provider %q. Use "github", "test" or a provider table.'):format(tostring(spec))
  end
  return require(module)
end

return M
