# Expertise

The notebooks in this folder are a shared memory for agents. They keep the facts that a senior engineer learns from experience, so that the next agent does not find them again.

Each technology has one notebook, such as `neovim.md`, `gh.md`, `claude.md` or `terminal.md`. To read a notebook, see "Notebooks" in [`AGENTS.md`](../../AGENTS.md#notebooks).

## What goes in a notebook

Add a fact only if all of these are true:

1. It is tricky or unexpected.
2. It is not well documented. It is not in the docs of the technology, such as `:h`, and not in the docs of this repo.
3. It has no natural place elsewhere, such as a code comment, `docs/DEVELOPMENT.md` or `docs/TESTING.md`.

## Add an entry

1. Add an entry when you find a fact, or when the user tells you a fact.
2. Check the fact before you add it. Run the proof on the installed version.
3. Put the entry in the section that it applies to. If no section applies, add a section.
4. Add the entry in the pull request of your task. If there is no task, open a separate pull request.
5. In the pull request description, list the entries that you added, changed or removed.

If the technology has no notebook, make the file. If a new section or file is necessary, make it. Do not stop to ask the user. Write it in the pull request description, so that the reviewer examines it.

## Entry format

````markdown
### <The fact, in one line>

<The details, and what to do. Use six sentences or fewer.>

- Proof: <a test, a command and its result, or a link to the docs or the source>
- Checked: <the version of the technology>
````

- The heading is the fact. Agents scan the headings to find the entries that apply to their work.
- Each entry must have a proof. Use the best proof that you can:
  1. A test in this repo. If the fact becomes false, the test fails.
  2. A command, with the result that it gives.
  3. A link to the docs, or to the source at a tag.

## Keep the entries correct

- If an entry is wrong, fix it or remove it in the pull request of your task.
- If a test that is a proof fails, fix the entry in the same change as the test.
- When the minimum version of a technology changes, run the proofs again.
