--- All GraphQL documents of the GitHub provider. Each field was examined against the live
--- GitHub GraphQL schema. See docs/architecture/review.md#gh-commands.

local M = {}

--- The PR data, the files and the pending reviews. `gh api graphql --paginate` gives the
--- `files` pages. Each page repeats the other fields.
M.change = [[
query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      id
      number
      title
      body
      isDraft
      author { login }
      baseRefName
      headRefName
      baseRefOid
      headRefOid
      isCrossRepository
      headRepositoryOwner { login }
      reviews(states: [PENDING], first: 10) {
        nodes { id viewerDidAuthor }
      }
      files(first: 100, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes { path changeType additions deletions }
      }
    }
  }
}
]]

return M
