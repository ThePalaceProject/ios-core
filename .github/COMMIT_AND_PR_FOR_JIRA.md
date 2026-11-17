# Commit and PR format

Commits and PRs are linked to Jira, so their text is what a colleague sees when
they expand a ticket. Write for someone opening the repo cold. The full rules are
in the "Writing conventions" section of [`CLAUDE.md`](../CLAUDE.md).

## Commit messages

```
Short imperative subject, 72 chars max (PP-XXXX)

Optional body, about 10 lines at most: what changed and why, in behavior
terms rather than a file list.
```

Example:

```
Keep book detail under the audiobook player in the nav stack (PP-3783)

pushAudioRoute() cleared the whole stack before pushing the player, so
My Books popped back to the catalog. Clear the stack only when replacing
an existing player.
```

- Put the Jira key in the subject (prefix or suffix). The post-commit and PR
  workflows pick it up from there.
- No `Co-Authored-By` trailer for AI tools and no "Generated with" line.
- No internal run or campaign identifiers in the subject or body.

## PR descriptions

Use the template in [`PULL_REQUEST_TEMPLATE.md`](./PULL_REQUEST_TEMPLATE.md):
**What**, **Why**, **How verified**, and optionally **Not done**. Aim for about
20 lines; `scripts/check-pr-hygiene.py` fails a body over ~1,500 characters
(images and HTML comments excluded).

When the PR is opened, `jira-pr-opened.yml` copies the **What** and **Why**
sections into a comment on each linked ticket and uses **How verified** as the
testing steps, so keep those sections readable on their own.
