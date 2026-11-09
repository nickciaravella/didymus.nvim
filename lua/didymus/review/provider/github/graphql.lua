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

--- The review threads of a PR, with the first comments of each thread. `gh --paginate` uses
--- the first `pageInfo` in the reply, so the `pageInfo` of the threads comes before the comments.
M.threads = [[
query($id: ID!, $endCursor: String) {
  node(id: $id) {
    ... on PullRequest {
      reviewThreads(first: 100, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          path
          line
          startLine
          diffSide
          startDiffSide
          isResolved
          isOutdated
          subjectType
          comments(first: 100) {
            pageInfo { hasNextPage }
            nodes { author { login } body state }
          }
        }
      }
    }
  }
}
]]

--- All comments of one review thread, for a thread with more comments than `M.threads` gets.
M.thread_comments = [[
query($id: ID!, $endCursor: String) {
  node(id: $id) {
    ... on PullRequestReviewThread {
      comments(first: 100, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes { author { login } body state }
      }
    }
  }
}
]]

return M
