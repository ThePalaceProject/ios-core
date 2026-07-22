<!-- audit-verified: PR #1320 body read directly (fix/jira-honest-build-claims → develop);
     PP-4822 / #1314 / #1316 / #1313 references taken from those PRs' own bodies in the review corpus -->
# The PR Report Contract

> The pull request is not a formality on the way to a merge. For a codebase whose
> changes are increasingly **authored by AI agents and orchestrated by a human**, the
> PR **is** the durable record and the fleet's telemetry surface. This document is the
> contract every reporting surface — the authored body, the test comment, the ledger
> comment, the roll-up — must serve. It is the single design that ties them together.

## Why this exists

An earlier review (captured in this PR's own history) found the reporting had inverted
its signal budget:

- The **authored layer** (PR bodies + commit messages) was genuinely world-class —
  root cause, mechanism, quantified before/after, honest `Not done` stanzas.
- The **automated layer** buried it — a ~900-row all-green test table dwarfed the
  15-line human body, the delta engine that computes *what changed* was silent, the
  architecture comment printed the same constant numbers on every PR, and a disabled
  integration shipped a standing "set OPENAI_API_KEY" banner on every page.
- Deeper, for an agent fleet: the load-bearing claims ("258/258 green",
  "mutation-verified") were **author-attested prose** with no machine anchor — and PR
  #1320 proved the automation had already fabricated claims (phantom TestFlight builds).

The fix is not "add more sections." It is to make every surface answer a specific
question for a specific reader, and to **delete or collapse everything that answers
none.**

## The four goals (who reads a PR, and why)

The old framing — "useful for a human reviewer" — assumed a human author writing for a
human reviewer. That is no longer the situation. The reader is an **orchestrator** who
cannot line-verify a fleet's output, plus a **forensic researcher** six months out. Four
goals, in priority order:

1. **Orchestrator decision speed.** From the PR header + body alone, decide
   *merge / hold / redirect* in under a minute. Noise must never bury the decision inputs.
2. **Grounded verifiability.** Every claim that carries weight — a pass count, a
   "mutation-verified", a "120s → 0.22s" — is anchored to **machine-checkable evidence**
   (a CI job, an uploaded log + exact command + exit status). A number with no pointer is
   a *hypothesis*, not a verification. An agent's confidence is not evidence.
3. **Durable forensic reconstruction.** Six months out, from **git + the PR alone**
   (links may be dead): the scenario that broke, the root cause, the fix, how it was
   verified, and *what was deliberately not done*. If it only lives behind a rotting
   `actions/runs/…` link or in Jira, it is not durable.
4. **Fleet-level legibility.** Recurrence classes, agent collisions, and convergence
   trends are **queryable across PRs**. No single PR can answer "is the flake rate
   trending down?" or "did another open PR just clobber this fix?" — the record must be
   shaped so an aggregate can.

## The four principles (how every surface behaves)

Each principle is enforced by a specific surface; the cross-references make the system
cohere.

### 1. Decision-first — verdict and delta before detail
The first screen answers "should I merge this?" A verdict line, then **what changed vs.
the base** (new failures, fixed tests, flaky), then the failing detail. The exhaustive
matrix (every passing class, every metric) is **always collapsed or linked, never
dumped**. Enforced by: the test comment (`unit-testing.yml`).

### 2. Delta-or-silent — a surface that never varies carries zero bits
A metric identical on every PR is decoration, and decoration trains readers to skim past
warnings. Post a metric **only when the diff moves it**, and **name** what moved. If the
diff changed nothing a surface measures, that surface stays quiet (or says so plainly) —
it does not print a green checkmark over zero analyzed files. Enforced by: the ledger
comment (`ledger.yml`).

### 3. Grounded-verifiability — no weight-bearing number without a pointer
The authored body may state a result only if it names where CI (or an attached artifact)
reproduces it. `swift test 258/258` is trust-me until the package suite runs in CI and
comments the number back. Enforced by: the `## Evidence` section of the body
(`PULL_REQUEST_TEMPLATE.md`) and, over time, package-suite CI jobs. The honest interim
state — "reproduced by CI job X" vs. "self-attested, not yet CI-reproduced" — is stated,
not hidden.

### 4. Fleet-legible — write the taxonomy down, don't trap it in prose
Agents already name recurrence classes in prose ("same debounce class as PP-4822", "same
unbounded-live-dependency as #1314"). Trapped in prose, it can't be counted. The body
declares `Class:` against a **greppable registry**
([`docs/regressions/recurrence-classes.md`](../regressions/recurrence-classes.md)) and
lists open `Obligations:` as checkboxes, so a roll-up can see recurrence counts and
un-discharged promises. Enforced by: the body template + the registry.

## Surface-by-surface responsibilities

| Surface | Owns | Serves | Rule it enforces |
|---|---|---|---|
| **Authored body** (`PULL_REQUEST_TEMPLATE.md`) | Root cause · Solution · **Evidence** · **Repro** · **Class** · **Obligations** · Scope · Not-done | 1,2,3,4 | Every weight-bearing number cites its evidence; every deferral is a tracked checkbox |
| **Commit messages** (`COMMIT_AND_PR_FOR_JIRA.md`) | Root cause + Solution per commit; squash concatenates them | 3 | The git record stands alone without the PR page |
| **Test comment** (`unit-testing.yml`) | Verdict → deltas → failures-first → full matrix collapsed/linked | 1,2 | Decision-first; failures open, passing matrix never dumped |
| **Ledger comment** (`ledger.yml`) | Architecture / reachability **deltas**, named | 1,2 | Delta-or-silent; name the violation; no green over zero files |
| **Recurrence registry** (`docs/regressions/recurrence-classes.md`) | The `Class:` taxonomy | 3,4 | One greppable id per failure class |
| **Cross-PR roll-up** (future) | Obligation debt, flake trend, `Class:` counts, open-PR file overlap | 4 | The orchestrator console |

## Questions the record must eventually answer (the standing gap list)

These are the orchestrator's cross-PR questions. Items not yet delivered are tracked as
`Obligations` on this PR and in the roll-up backlog — they are named here so the gaps stay
visible instead of reading as "done."

1. Did the agent actually run what it claims? *(Evidence section; package-suite CI job — partially open.)*
2. What failed on iterations 1..N−1 of this PR? *(Sticky comment overwrites red history — open: freeze-before-overwrite.)*
3. *Why* did a test fail — message + first stack frame, not just a name? *(Test comment inlines failure detail — delivered.)*
4. Is flake rate trending down since the deflake campaign? *(Delta engine renders but `.test-history` cache misses on PR branches — open: develop cache-warm job.)*
5. Has this failure class occurred before, and where? *(Registry + `Class:` — delivered as a seam.)*
6. Which open PRs conflict with this one? *(Open: roll-up file-overlap check.)*
7. Were the `Deferred:` / "will post before merge" obligations discharged? *(`Obligations:` checkboxes — delivered as a seam; reconciliation is open.)*
8. What does the ledger's "1 layer violation" refer to? *(Ledger now names it — delivered.)*
9. Can I re-run the repro? *(`Repro:` links the simdrive replay — delivered as a seam.)*

## What this PR delivers vs. defers

**Delivered:** the contract (this doc); the authored-layer template + convention link; the
recurrence registry seed; the test comment made decision-first (verdict → deltas →
failures-first → matrix collapsed, skipped surfaced so no false-green rows); the ledger
comment made delta-honest (violation named, no green over zero files, dead QAAtlas banner
removed).

**Deferred (tracked as Obligations on this PR):** the `.test-history` develop cache-warm
job (so deltas actually populate); freeze-red-before-overwrite; the package-suite CI job
that reproduces the `swift test` numbers; the cross-PR roll-up; the ~2 unmapped-status
tests in `parse-xcresult.py`.

The point of shipping the deferrals *as named obligations* rather than silently is the
contract dogfooding itself: this PR is reported in exactly the form it defines.
