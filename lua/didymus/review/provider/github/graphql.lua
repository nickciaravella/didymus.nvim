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

--- The fields of a review comment.
local comment_fields = "author { login } body state"

--- The fields of a review thread, with its first comments.
local thread_fields = [[
id
path
line
startLine
diffSide
startDiffSide
isResolved
isOutdated
subjectType
viewerCanReply
viewerCanResolve
viewerCanUnresolve
comments(first: 100) {
  pageInfo { hasNextPage }
  nodes { ]] .. comment_fields .. [[ }
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
]] .. thread_fields .. [[
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
        nodes { ]] .. comment_fields .. [[ }
      }
    }
  }
}
]]

--- The pending reviews of a PR. Only the viewer can see a pending review, but `viewerDidAuthor`
--- makes sure.
M.pending_reviews = [[
query($id: ID!) {
  node(id: $id) {
    ... on PullRequest {
      reviews(states: [PENDING], first: 10) {
        nodes { id viewerDidAuthor }
      }
    }
  }
}
]]

--- Start a pending review. With no `event`, the review stays pending.
M.start_review = [[
mutation($pullRequestId: ID!, $commitOID: GitObjectID!) {
  addPullRequestReview(input: { pullRequestId: $pullRequestId, commitOID: $commitOID }) {
    pullRequestReview { id }
  }
}
]]

--- Add a thread on the head side to a pending review. `startLine` and `startSide` are null for a
--- comment on one line.
M.add_thread = [[
mutation(
  $reviewId: ID!
  $path: String!
  $body: String!
  $line: Int!
  $startLine: Int
  $startSide: DiffSide
) {
  addPullRequestReviewThread(input: {
    pullRequestReviewId: $reviewId
    path: $path
    body: $body
    subjectType: LINE
    side: RIGHT
    line: $line
    startLine: $startLine
    startSide: $startSide
  }) {
    thread {
]] .. thread_fields .. [[
    }
  }
}
]]

--- Add a reply to a thread, in a pending review.
M.reply = [[
mutation($reviewId: ID!, $threadId: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {
    pullRequestReviewId: $reviewId
    pullRequestReviewThreadId: $threadId
    body: $body
  }) {
    comment { ]] .. comment_fields .. [[ }
  }
}
]]

--- Resolve a thread, and `M.unresolve` unresolves it. The reply has the thread, because the
--- `viewerCan…` fields can change.
M.resolve = [[
mutation($threadId: ID!) {
  resolveReviewThread(input: { threadId: $threadId }) {
    thread {
]] .. thread_fields .. [[
    }
  }
}
]]

M.unresolve = [[
mutation($threadId: ID!) {
  unresolveReviewThread(input: { threadId: $threadId }) {
    thread {
]] .. thread_fields .. [[
    }
  }
}
]]

return M
