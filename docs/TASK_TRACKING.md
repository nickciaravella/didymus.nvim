# Task tracking

We track work in GitHub issues. Each issue belongs to one epic.

## Epics

Each epic is a GitHub label.

| Label | Scope | Architecture doc |
| --- | --- | --- |
| `agent` | Interaction with the agent: questions, follow-ups, and links from the agent back to the code. | [`architecture/agent.md`](architecture/agent.md) |
| `agentic-dev` | Tools, docs and skills that help agents work on didymus.nvim, such as a memory of domain knowledge. | None |
| `diff` | Presentation and navigation of the diff, across all files in the change. | None |
| `review` | Review actions: pick a change, comment, reply, resolve, approve. | [`architecture/review.md`](architecture/review.md) |

## Rules

1. Give each issue one epic label.
2. Do infrastructure work only when an epic needs it. Do not build it before.
3. Give an infrastructure issue the label of the epic that needs it first.

## Commands

```sh
gh issue create --label review   # make an issue in the review epic
gh issue list --label diff       # list the issues in the diff epic
```
