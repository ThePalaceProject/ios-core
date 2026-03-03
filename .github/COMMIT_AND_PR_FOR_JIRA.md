# Commit and PR format for JIRA

When commits or PRs are linked to JIRA, the default post often shows only hash, author, date, one-line message, and file list. To make JIRA posts **useful** (root cause, what changed, how to verify), use the formats below.

---

## Commit message format

Use a short subject line with ticket id, then a body with **Root cause** and **Solution**. The body is what shows up when someone expands the commit in JIRA or in changelogs.

```
Short imperative summary (PP-XXXX)

Root cause: One or two sentences on why the bug happened or why the change is needed.
Solution: What this commit does (behavior change, not file list).
```

**Example:**

```
Fix My Books from audiobook player returning to catalog (PP-3783)

Root cause: pushAudioRoute() cleared the entire nav stack before pushing the
player, so the stack became [Audio] instead of [BookDetail, Audio]. Tapping
My Books then popped to root (catalog).

Solution: Track whether the top route is audio; only clear the stack when
replacing an existing player (e.g. switching audiobooks). When opening from
book detail, push audio without clearing so back goes to book detail.
```

---

## PR description: "Summary for JIRA" block

In the PR description, fill in the **Summary for JIRA** section (see the PR template). That block is easy to copy into the JIRA ticket or to use for release notes. Include:

- **JIRA:** Ticket id(s).
- **Root cause:** Why the bug happened or why we're making the change.
- **Solution:** What the PR does (user-visible and key technical points).
- **How to verify:** Short QA steps or test instructions.

---

## Why this helps

- **JIRA:** Linked commits/PRs show *why* and *what*, not just "Fix X" and file names.
- **Code review:** Reviewers see context without opening the ticket.
- **Release notes:** Copy the Summary for JIRA block into release notes.
- **Future you:** In six months, the commit and PR still explain the change.
