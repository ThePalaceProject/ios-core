# Contract F — FireAndForgetAudit

## Scope

**PURE AUDIT.** Spot-check 170 Task/`DispatchQueue.async` occurrences in `PalaceTests/`. Classify each into:

1. **Utility drainers (OK)** — e.g. `XCTestCase+drainMainQueue.swift`. Test-helper utilities that exist to drain queues.
2. **Test-only awaited Task (OK)** — `Task { … }` whose result is awaited in the test body before tearDown.
3. **Production fire-and-forget reachable from tests (flag for follow-up)** — production code spawning `Task { … }` or `DispatchQueue.async { … }` without retention/cancellation, where the test cannot await it.

### Output

Write to `.forgeos/swarms/swarm_47883816/transcripts/F-audit.md` with sections:

- Summary (counts per category)
- Grep evidence per finding
- Recommended follow-up tickets (Jira / GitHub issue numbers) for any category-3 findings
- Optional: ≤2 trivial fixes inline with explicit justification

### Code changes

**Default: 0 code changes.** If audit finds ≤2 trivial fixes (e.g. a single missing `Task` reference assignment, a single missed `cancellables` registration), F implementer may submit them as part of this contract WITH explicit transcript justification per fix. Otherwise file follow-up issues only.

## Off-limits

- ALL code files unless the ≤2-trivial-fix carve-out is invoked
- Any production change in critical paths (auth, borrow, return, download, DRM, audiobook) — those go to follow-up regardless of triviality

## Verification criteria

| # | Criterion | Command |
|---|---|---|
| 1 | Audit doc exists and is complete | `[ -f .forgeos/swarms/swarm_47883816/transcripts/F-audit.md ]` |
| 2 | Counts match grep | `grep -rEn "Task\s*\{\|DispatchQueue\.(global\|main)\.async" PalaceTests --include="*.swift" \| wc -l` ≈ documented total in audit doc |
| 3 | Each category-3 finding has a tracked follow-up | Issue numbers / TODO comments cited in the audit doc |
| 4 | No code changes if >2 fixes proposed | `git diff` shows only the audit doc + at most 2 code fix patches |
