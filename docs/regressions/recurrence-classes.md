<!-- audit-verified: class descriptions and PR/ticket anchors taken from the referenced
     PRs' own bodies (the review corpus); ids are new labels coined here for the registry -->
# Recurrence-class registry

A **greppable taxonomy of failure classes.** Agents already identify recurrence in prose
("same debounce class as PP-4822", "same unbounded-live-dependency as #1314"). Trapped in
prose it cannot be counted; here it can. Each PR's body declares `Recurrence-of: <id>`
against this file (see [the contract](../architecture/pr-report-contract.md), §4).

**How to use.** Fixing an instance of a known class → cite its `id` in the PR body. Hitting
a genuinely new class → add a row here in the same PR, then cite it. A roll-up greps
`Recurrence-of:` across merged PRs to surface which classes keep recurring — the signal
that the *class* needs a structural fix, not another instance patch.

| id | Class | Signature (how you recognize an instance) | Structural fix | Seen in |
|----|-------|-------------------------------------------|----------------|---------|
| `unbounded-live-dependency` | A test reaches an unbounded, real external dependency (live OSLogStore, network, `withTimeout` that doesn't bound a non-cancellable op) | Full-suite hang / timeout; passes alone; the "guard" test masks it because its stand-in *is* cancellable | Inject a bounded/fake dependency; assert the bound in a deterministic seam | #1314, #1316 |
| `debounce-missing` | A rapidly-retriggered UI action (chips, category taps) fires N times instead of once | Duplicate side-effects under fast input; chaos-QA rapid-tap reproduces | Debounce at the source; test with a burst-input harness | PP-4822, PP-4823, PP-4843 |
| `redaction-shape-gap` | A new phrasing of sensitive input (prose password, card/PAN, bidi controls) slips past redaction keyed on the previous shape | Sensitive value appears in a log/report; AC gate + unit tests keyed to the old shape miss it | Normalize input before matching; add the new shape to the redaction corpus | F-002, PP-4842 |
| `parallel-clone-starvation` | Deadline-polling tests fail under parallel test clones competing for a shared resource | Flake concentrated on deadline/poll tests; serial run is green | XCTest-gated deterministic Task-join seam replacing wall-clock deadline | #1319, #1321 |
| `stale-snapshot-clobber` | One agent's merge lands a pre-change snapshot that silently reverts another agent's fix | A shipped fix reappears broken after an unrelated merge; discovered post-merge | Roll-up file-overlap check across open PRs; re-land + snapshot refresh | #1310 → #1313 |
| `deflake-destroys-the-signal` | De-flaking a test removes the flake AND the only signal that would reveal a real bug | An immediate, un-retried read of state written through an async bridge; the flaking assertion is the one the test exists for; the proposed fix is "wait until it appears" | Distinguish the causes first (instrument the seam so the two are separable), or keep the strict assertion, mark it, and track it — never quieten it before the question is answered | #1431 |

> New class? Add a row (stable kebab-case `id`, a signature a future reader can pattern-match
> on, and the structural fix if known), then reference it from the PR body. Keep ids stable —
> they are cited from merged PR bodies and a rename orphans the history.
