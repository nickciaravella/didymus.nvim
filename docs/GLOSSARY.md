# Glossary

Use these terms with these meanings. Add terms when we decide on them.

| Term | Meaning |
| --- | --- |
| Agent | An AI CLI, such as Claude Code or Codex. |
| Base | The branch or commit that the change goes into. |
| Change | The thing under review. On GitHub, a pull request (PR). |
| Code host | The system that keeps the change, such as GitHub. |
| End-to-end test | A test that drives a child Neovim the way a user does. |
| Epic | A large stream of work. Each epic is a GitHub label. |
| Head | The commit with the new code. |
| Hunk | One block of changed lines. |
| Integration | A replaceable part that connects core to a code host, an agent or a diff tool. |
| Integration test | A test that checks one integration against its interface. |
| Local provider | A provider that keeps changes in a local git repo. End-to-end tests use it in place of GitHub. |
| Merge-base | The common ancestor of base and head. |
| Pending review | A review that is started but not submitted. |
| Provider | An integration for a code host, such as GitHub. |
| Reference file | `docs/reference/design-prompt.md`. A first pass at the design. Not a spec. |
| Thread | A list of comments on one line or range. |
