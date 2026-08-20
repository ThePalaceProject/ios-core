---
name: jira-ticket
description: Create or update Palace (PP) Jira issues in the house documentation style — plain, patron-focused language that explains the WHY and the rough scope in words, not code-soup. Use whenever the user says "create a jira story/ticket/epic", "file a PP ticket", "make subtasks", "point this", "assign to me", "put it in the sprint", "move it to In Progress / Code Review / Done", or asks to track work in Jira. Encodes the PP project's field IDs, board + active-sprint lookup, Fibonacci story points, the Story→Sub-task shape, and the In Progress → Code Review → Done workflow so every ticket comes out consistent.
tools: Bash, Read
---

# /jira-ticket — house style + PP conventions for Jira work

Every Palace Jira issue we author reads like a **product person wrote it**: it opens
with the patron-facing problem, explains WHY the work matters, and lists the scope in
plain words. It is NOT a code changelog. A reviewer, a PM, or a librarian should be able
to read the description and understand what's changing and why — without knowing Swift.

This skill captures (1) that writing style and (2) the mechanical PP conventions
(field IDs, board, sprint, transitions) so tickets are consistent every time.

---

## 1. The documentation style (this is the important part)

**Exemplar to match:** the Swift 6 epic stories `PP-4719` … `PP-4725` (epic `PP-4717`).
Read one before writing (`jira_get_issue PP-4722 fields=description`) if you need a refresher.

Rules:

- **Lead with the patron, not the code.** Open with what a person experiences or why it
  matters. "Book covers pop in instead of fading" — not "add `.animation(value:)` to
  `BookImageView`."
- **Explain the WHY.** Every ticket says why the work is worth doing and, where relevant,
  why it's sequenced the way it is (e.g. "this comes first because …").
- **Scope in words, with rough magnitudes.** "About 62 warnings", "the seven internal
  packages", "roughly a hundred call sites", "~200 lines of dead code." Give the reader a
  sense of size without a file manifest.
- **Plain-language bullets.** Break the work into readable bullets. Each bullet is a
  sentence a non-engineer understands. A file path or symbol is fine when it genuinely
  aids a reviewer, but it rides *inside* a plain sentence — it never replaces one.
- **State the boundaries.** Note what's explicitly out of scope, what's gated on other
  work, and what "done" looks like ("Done when: … CI is green").
- **No dumping the audit.** If there's a detailed technical source (a design doc, an
  audit artifact, a scan), link or reference it and keep the ticket readable. Depth lives
  in the linked doc; the ticket carries the story.
- **Active voice, present/future tense, honest about risk.** "This is low-risk, but it
  touches configuration, so a clean build across the full suite is the signal it's safe."

Anti-patterns (do NOT ship these):
- A bare bullet list of `file:line` changes with no narrative.
- Copy-pasting the implementation plan or the diff.
- Jargon a librarian couldn't parse in the first paragraph.
- One-liner descriptions ("Bump iOS target.") with no why/scope/done.

**Structure:** default to a **Story with Sub-tasks**, one sub-task per shippable PR /
stage. Use an **Epic with Stories** only when the effort is large enough that each child
is itself multi-PR (the Swift 6 work is an epic for that reason). Give the Story the
narrative arc; give each sub-task its own self-contained why + scope + done — a sub-task
should read well on its own, because that's the card someone actually works.

---

## 2. PP mechanical conventions (discovered, keep current)

Jira site: `ebce-lyrasis.atlassian.net` · Project key: **PP** ("The Palace Project").

| Thing | Value / how to get it |
|---|---|
| Scrum board | **"PP board"**, id **4** (`jira_get_agile_boards project_key=PP board_type=scrum`) |
| Active sprint | look it up, don't hardcode: `jira_get_sprints_from_board board_id=4 state=active` -> sprint `id` |
| **Story Points field** | **`customfield_10033`** (float). NOT `customfield_10016` (that one is unused here). |
| Point scale | **Fibonacci** "human values": 1, 2, 3, 5, 8, 13, 21. Size honestly; don't invent 4s and 7s. |
| Sub-task type name | **`Sub-task`** (with the hyphen), not `Subtask`. Link via `additional_fields: {"parent": "PP-####"}`. |
| Assignee | by email works — e.g. `maurice.carrier@outlook.com`. |

Workflow **transition IDs** (from `jira_get_transitions`; stable on this board):

| Status | id |
|---|---|
| To Do | 11 |
| **In Progress** | **21** |
| **Code Review** | **51** |
| QA/Review | 61 |
| Design Review | 71 |
| Done | 31 |
| Ready to Deploy | 81 |
| Closed | 41 |

Set points at create time via `additional_fields: {"customfield_10033": <n>}`
(and `"parent"` for sub-tasks). Example create:

```
jira_create_issue
  project_key: PP
  summary: "PR2 · P0 shared motion foundations"
  issue_type: Sub-task
  assignee: maurice.carrier@outlook.com
  description: <house-style markdown>
  additional_fields: {"parent": "PP-4743", "customfield_10033": 8}
```

**Sprint placement:** sub-tasks inherit their parent's sprint — you cannot add a sub-task
to a sprint on its own. Add the **parent Story** to the active sprint:
`jira_add_issues_to_sprint sprint_id=<active> issue_keys="PP-####"`. The Story also
auto-moves to *In Progress* once any sub-task is *In Progress*; that's expected.

---

## 3. Three gotchas that will bite you

1. **`jira_create_issue` `description` stores `\n` literally.** Passed as a plain
   parameter, the two-character sequence `\n` is saved verbatim (you get literal `\n` in
   the ticket). Put **real newlines** in the `description` value. If you already created a
   mangled one, fix it with `jira_update_issue` where the `fields` JSON *does* interpret
   `\n` as a newline: `fields: {"description": "line one\nline two"}`.
2. **Transition comments must be Atlassian Document Format.** `jira_transition_issue`'s
   `comment` param rejects markdown ("Operation value must be an Atlassian Document").
   Just omit the comment on the transition; if you want a note, post it separately with
   `jira_add_comment` after the transition.
3. **The create response is NOT what Jira stored — read the issue back and *diff* it.**
   `jira_create_issue` echoes a cleaned-up `description` in its result. That echo is a
   rendering of what you sent, not a read of what the server holds, so it looks like
   verification and is not. One create call on PP-4997 produced **three** independent
   corruptions, none visible in the echo:
   - Markdown headings persisted escaped (`**Heading**` -> `\*\*Heading\*\*`) and render
     as literal asterisks. Use Jira wiki `h3.` headings instead of `**bold**`.
   - Every blank line was eaten, gluing headings to their paragraphs.
   - `+` characters were silently dropped: a quoted PR title, "durable downloads +
     registry resilience + offline-safe loans", stored double-spaced where each `+` had
     been — a misquoted citation in a ticket whose argument rested on citing that PR.
     (`+text+` is also Jira wiki underline, so avoid `+` in prose entirely.)

   After creating, call `jira_get_issue ... fields=description` and **compare the stored
   text against what you sent**. Do not skim it for the problem you already suspect: on
   PP-4997 a reviewer did read the issue back and still caught only one of the three,
   because they went looking for the escaped asterisks and read straight past the dropped
   plus signs sitting in the same response. Reading the artifact back is necessary and
   not sufficient — diff, don't scan. Fix what you find with `jira_update_issue`.

---

## 4. Workflow: move cards as the work actually moves

When this skill is used alongside real delivery, keep Jira honest in lockstep:

- **Starting a stage** -> transition its sub-task to **In Progress** (id 21).
- **PR opened / up for review** -> **Code Review** (id 51).
- **PR merged** -> **Done** (id 31).

Do the transition at the moment the state changes, not in a batch at the end — the point
of the board is that it reflects reality right now.

---

## Checklist before you call it done

- [ ] Description leads with the patron / the why, scope in plain words, explicit "done when".
- [ ] Reads well to a non-engineer; no diff-dump, no `file:line` soup.
- [ ] Story + Sub-tasks (or Epic + Stories) shape fits the size; each child self-contained.
- [ ] Real newlines in descriptions (not literal backslash-n).
- [ ] Issue read back with `jira_get_issue` and DIFFED against what was sent (the create echo is not the stored text).
- [ ] Pointed with a Fibonacci value on `customfield_10033`; assigned; parent Story in the active sprint.
- [ ] Statuses reflect reality (In Progress / Code Review / Done set as work moves).
