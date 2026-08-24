# Documentation map

Start here. This page answers two questions: **where do I look for something**,
and **where does a new document go**.

The codebase is meant to be readable as a record of the decisions that shaped
it. That only works if the record is small enough to read and true enough to
trust — so the rule is not "write more docs", it is **write the ones that
survive the admission test below, index them, and delete the rest**.

## Where to look

| I need… | Go to |
|---|---|
| Why the code is shaped this way — a decision and its rationale | [`architecture/`](./architecture/) — start at its [index](./architecture/README.md) |
| Whether an area is safe to change, and what to re-verify | `architecture/areas/<area>/verification-checklist.md` |
| How this project tests, and what a good test looks like | [`Testing/`](./Testing/) — [`TESTING_POSTURE.md`](./Testing/TESTING_POSTURE.md) first |
| The release regression pass | [`regression-suite/DESIGN.md`](./regression-suite/DESIGN.md), [`Testing/REGRESSION_TEST_MATRIX.md`](./Testing/REGRESSION_TEST_MATRIX.md) |
| A recurring failure and its class | [`regressions/recurrence-classes.md`](./regressions/recurrence-classes.md) |
| How to run something operationally | [`Operations/`](./Operations/) |
| How to investigate a reported bug | [`bug-investigation-process.md`](./bug-investigation-process.md) |
| **A case where verification passed while the bug was live** | [`../.forgeos/wall-failures/INDEX.md`](../.forgeos/wall-failures/INDEX.md) |
| Build, test, and workflow rules that bind every change | [`../CLAUDE.md`](../CLAUDE.md) |

**Search order for an agent.** `CLAUDE.md` → this map → the area's
verification-checklist → the ADR → the code. Going straight to a grep across all
docs ranks a spent plan equal to a maintained decision; the indexes exist so that
ranking is done for you.

## Where a new document goes

Apply the admission test first: **would someone make a materially worse decision
without this?** The code, its tests, and the git history already record what
happened and how it works — and unlike prose they cannot drift. A document earns
its place only by holding something that left no trace in the tree: a road not
taken, a constraint that is invisible from the code, a failure whose cause is not
recoverable from the diff.

| The thing you want to write | Where it goes | Or: don't |
|---|---|---|
| A decision and why the alternatives lost | `architecture/<topic>.md`, **added to the architecture index** | — |
| What to re-verify when touching an area | `architecture/areas/<area>/verification-checklist.md` | — |
| A verification that passed while the defect was live | `.forgeos/wall-failures/`, **added to its INDEX** | — |
| A pre-change contract (claims / anti-claims / files) | `.forgeos/intent/` via `/intent` | — |
| A plan for work about to start | | Nowhere. Put it in the Jira ticket. A landed plan is exhaust; an unlanded one is a ticket. |
| A run log, agent transcript, or campaign handoff | | Nowhere. `check-doc-hygiene.sh` blocks it. Distill the durable part into an ADR. |
| A raw review dump | | Nowhere. The ADR is the distillation; the review is the input. |
| A point-in-time report on a version no longer shipping | | Nowhere. Act on the finding; the finding's fix is the record. |
| A generated render (`.html`, `.arch/` IR) | | Nowhere. It is regenerable, so it is not a source of truth. |

## What keeps this honest

Prose is the only layer in this repo that can lie, so three mechanical gates hold
it to account. All three run in `tooling-checks.yml` on every PR, and the first
two also run in `verify-pr.sh`:

- **`check-doc-hygiene.sh`** — blocks process and generated artifacts from being
  committed at all. Denied classes are listed in the script.
- **`check-doc-references-resolve.py`** — every script, workflow, and source path
  a doc names must exist. Pre-existing breakage is baselined in
  `scripts/doc-references-baseline.json`; nothing new may be added, and a
  baseline entry that starts resolving also fails, so the amnesty cannot grow or
  go stale. This exists because the decomposition waves moved files into
  `Palace/Packages/*` and left 37 doc pointers aimed at addresses that no longer
  existed.
- **`check-doc-index-complete.py`** — every doc in an indexed directory must be
  named in that directory's index. An unindexed doc is one nobody will find,
  which makes it indistinguishable from a deleted one while still costing every
  future search. This exists because the architecture index described 6 of 53
  documents.

A doc you will not maintain is worse than no doc: a reader trusts it. If you
cannot keep it true, delete it — git history keeps it, and the gates stop
counting it.
