---
name: submit-pr
description: Submit a pull request for didymus.nvim with the project description template. Use when the user asks to open, submit, prepare or update a pull request.
---

# Submit a pull request

## Steps

1. Run `make test` and `make fmt-check`. If a check fails, fix it or tell the user.
2. If you are on `main`, make a new branch.
3. Commit the change. Use STE100 in the commit message.
4. Push the branch.
5. Find the issue that the change closes. If there is no issue, ask the user.
6. Write the description from the template below.
7. Open the pull request with `gh pr create --label <epic>`. Use the epic of the issue. See `docs/TASK_TRACKING.md`.
8. Give the user the link.

To update the description of a pull request, use `gh pr edit <number> --body-file <file>`.

## Template

```markdown
Closes #<issue>

## What Changed

<What changes for the product, and why. Do not give technical details.>

## How It Was Changed

<A short summary of the technical details.>

## How It Was Tested

<The test methods: unit, end-to-end, integration, manual.>

## Follow-up Issues

<A list of issues for later work, or "None".>
```

## Rules

- Use STE100. See `AGENTS.md`.
- Keep each section short. Use bullet lists.
- Write the results of the tests that you ran. If a check did not run, say so and tell why.
- Add screenshots to "How It Was Tested" if you captured them. `gh` cannot upload images, so tell the user which images to add.
- Make a follow-up issue only when the user agrees. Give it an epic label.
- End the description with the attribution line, if the session gives one.
