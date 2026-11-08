# Glossary

Use these terms with these meanings. Add terms when we decide on them.

| Term | Meaning |
| --- | --- |
| Agent | An AI CLI, such as Claude Code or Codex. |
| Agent session | One agent process, with its backend and its view. |
| Append | Put context in the agent input, and focus the agent. Do not submit. |
| Backend | The integration that runs an agent and gives prompts to it, such as `terminal`. |
| Base | The branch or commit that the change goes into. |
| Change | The thing under review. On GitHub, a pull request (PR). |
| Code host | The system that keeps the change, such as GitHub. |
| Context | A part of the code that goes with a prompt: the path, the lines, the text and the filetype. |
| End-to-end test | A test that drives a child Neovim the way a user does: with commands, keys and the public API. |
| Epic | A large stream of work. Each epic is a GitHub label. |
| Fake agent | A small CLI that acts like an agent in tests. |
| Head | The commit with the new code. |
| Hunk | One block of changed lines. |
| Integration | A replaceable part that connects core to a code host, an agent or a diff tool. |
| Integration test | A test that checks one provider or external dependency against the real thing. It can use more than one module. |
| Local provider | A provider that keeps changes in a local git repo. End-to-end tests use it in place of GitHub. |
| Merge-base | The common ancestor of base and head. |
| Notebook | A file of tricky facts about one technology, for agents, such as `agents/expertise/neovim.md`. |
| Pending review | A review that is started but not submitted. |
| Prompt | The text for the agent, and its context. |
| Provider | An integration for a code host, such as GitHub. |
| Reference file | `docs/reference/design-prompt.md`. A first pass at the design. Not a spec. |
| Send | Submit a prompt with its context. Do not show the agent. |
| Test backend | A backend without a process. End-to-end tests use it for the agent flows. |
| Thread | A list of comments on one line or range. |
| Unit test | A test of a pure function, or of a function that uses only Neovim. It has no external dependencies. |
| View | The window that shows an agent session: a float or a split. |
