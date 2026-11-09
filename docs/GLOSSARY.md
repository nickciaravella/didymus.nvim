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
| Integration | A replaceable part that connects core to a code host, an agent, a diff tool or a picker. |
| Integration test | A test that checks one provider or external dependency against the real thing. It can use more than one module. |
| Merge-base | The common ancestor of base and head. |
| Notebook | A file of tricky facts about one technology, for agents, such as `agents/expertise/neovim.md`. |
| Panel | A picker list that stays open next to the code, such as the files panel. |
| Pending review | A review that is started but not submitted. |
| Picker | A plugin that shows a list of items and lets the user choose one, such as snacks.picker. |
| Picker adapter | The integration that connects didymus to a picker. |
| Prompt | The text for the agent, and its context. |
| Provider | An integration for a code host, such as GitHub. |
| Reference file | `docs/reference/design-prompt.md`. A first pass at the design. Not a spec. |
| Review session | One open review: the change, its tabpage, and the branch from before the review. |
| Review tabpage | The tabpage of one review, with the files panel and the code. |
| Send | Submit a prompt with its context. Do not show the agent. |
| Test backend | A backend without a process. End-to-end tests use it for the agent flows. |
| Test picker | A picker adapter with no UI. End-to-end tests use it to choose items. |
| Test provider | A provider that keeps changes in memory. End-to-end tests use it in place of GitHub. |
| Thread | A list of comments on one line or range. |
| Unit test | A test of a pure function, or of a function that uses only Neovim. It has no external dependencies. |
| View | The window that shows an agent session: a float or a split. |
| Workspace | The git checkout of a review. In the MVP, the current checkout. |
