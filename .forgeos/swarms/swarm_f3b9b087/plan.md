# Swarm Plan — `swarm_f3b9b087` — 3.2.0 review-driven quality pass

## Goal

Land a 12-item review-driven quality pass for Palace iOS 3.2.0 across four implementer
buckets. Items cluster around read-position correctness (EPUB + audiobook), borrow-flow
hardening, notification-retry on auth-state transitions, and user-facing error message
quality. The pass is review-driven (originates from a code review, not an in-field
crash report) so we have the luxury of triaging carefully and writing
mutation-killing tests up front. All twelve items go in as a single coordinated
release-candidate cut for 3.2.0.

## Module bucketing rationale

The 12 items map onto four implementer buckets, sized to the CLAUDE.md 200–600 LOC
sweet spot. Bucketing was driven by **shared file ownership** (avoiding parallel
edits to the same Swift file) and **shared mental models** (e.g. read-state
correctness is a different mental model than borrow-flow state machines).

| Bucket | Items | Files | LOC est. | Critical path? |
|---|---|---|---|---|
| **Reader2-ReadState** | #1, #2, #3 | 3 prod + 3 test | 250–350 | Adjacent (mutation goal 50%) |
| **Audiobook-Position** | #4, #5, #10 | 2 prod + 2 test | 400–500 | YES (mutation goal 75%) |
| **MyBooks-Borrow** | #7, #8, #12 | 4 prod + 3 test | 350–500 | YES (mutation goal 75%) |
| **Notifications-OPDS-Errors** | #6, #9, #11 | 3 prod + 4 test | 250–350 | NO (mutation goal 50%) |

**Item #11 (Info.plist UIBackgroundModes audio):** already satisfied in
`PalaceConfig/Palace-Info.plist`. Folded into Notifications-OPDS-Errors as a
30-second verification line in the PR description rather than its own bucket.

**Why these splits and not others:**

- Items #1–3 (Reader2-ReadState) all touch Reader2 internals and share the
  "locator correctness + WKWebView race" theme. Splitting them across implementers
  would force file-level conflicts on `TPPReadiumBookmark.swift`'s test file.
- Items #4–5 + #10 (Audiobook-Position) all touch audiobook position state.
  Item #10 (chapter TOC normalization) is in the same file (`AudiobookSessionManager.swift`)
  as item #5 (`getValidLocalPosition`), forcing them into the same bucket regardless.
- Item #6 (Notifications-FCM) alone is too small (~100 LOC). Items #9 + #11
  are tiny. Folding them into one bucket gives a respectable 250–350 LOC range
  and the implementer's mental load is manageable (all three are independent
  diffs in different files).
- Items #7, #8 (BorrowOperation) are intertwined — the SQ-007 spinner cleanup
  depends on the same predicate flow as the 401-no-problem-doc fallthrough.
  Item #12 (download task-identifier map) goes with them because borrow→download
  is the natural sequence and the implementer needs MyBooks context.

## Parallelism plan

**Four implementer subagents, all parallel** — bucketing is designed so no two
buckets touch the same Swift file. The orchestrator integrator can merge in
any order. Suggested order if serialization is needed:

1. Audiobook-Position first (highest mutation bar, highest LOC, most context-sensitive).
2. MyBooks-Borrow second (contract snapshot updates need careful review).
3. Reader2-ReadState third.
4. Notifications-OPDS-Errors fourth (depends on no other bucket; can be done in parallel by an Opus-4.7 agent in ~30 min).

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| **User-facing copy ships without design review** (item #9) | Contract explicitly requires placeholder NSLocalizedString key + "REQUIRES DESIGN APPROVAL" call-out in PR body. Memory `feedback_no_new_copy_without_design` referenced. |
| **Contract snapshot drift breaks build** (item #8 — BorrowOperationContractTests) | Implementer instructed to set `CONTRACT_SNAPSHOT_RECORD=1`, diff the JSON, verify ordering. Snapshot review is part of PR review. |
| **Audiobook position is critical-path; weak tests slip through** (items #4, #5) | Mutation goal raised to **75%** for this bucket (vs 50% baseline). Boundary tests required for every threshold (`< 30.0`, `* 1.1`, `>= 0`, `.isFinite`). |
| **PalaceAudiobookToolkit submodule entanglement** (item #5) | Contract explicitly forbids touching the submodule. If a submodule bug is exposed, document and defer. |
| **`taskIdentifierToBook` recycle bug may not actually manifest** (item #12) | Contract permits the implementer to document a "verified safe via call-site audit, no code change needed" outcome in the `**Not done:**` stanza. |
| **WKWebView race (item #3) is hard to unit-test** | Contract offers two acceptable patterns: behavior-shape test with stub Navigator, OR contract snapshot. Implementer picks; mutation goal still applies. |
| **Concurrent file edits across buckets** | Bucket scopes are mutually exclusive at file level. Verified via grep before contracts were written. Each contract has an explicit "Files OFF-LIMITS" section. |
| **Implementer adds public API surface that wasn't scoped** | Each contract has "Public type / protocol / signature changes" with explicit "STOP and consult integrator" guards. |
| **Worktree branch-flip from concurrent claude sessions** | Memory `feedback_concurrent_claude_branch_flip` — implementers work in separate worktrees. Orchestrator integrates here. |

## Acceptance criteria (swarm-wide)

- All four contracts merged into the integrator branch (`swarm/swarm_f3b9b087-scaffold`).
- `scripts/verify-pr.sh --quick --enforce-mutations` passes for the integrated diff against `origin/develop`.
- Critical-path files (`BorrowOperation.swift`, `AudiobookBookmarkBusinessLogic.swift`,
  `AudiobookSessionManager.swift`) show **≥75% mutation kill rate** on diff-scoped runs.
- Non-critical-path files show ≥50% diff-scoped mutation kill.
- Contract snapshot updates reviewed and committed.
- Every commit has `**Scope:**` and `**Not done:**` stanzas (CLAUDE.local.md hook will reject otherwise).
- No `.shared` reads in new test code (CLAUDE.md TDD rules).
- No force unwraps. No `sleep` in tests. No tautology tests.
- No new user-facing copy ships without explicit design approval call-out in PR body.
- ForgeOS gates: init → propose changeset → submit evidence → review (forge-review) → promote.
- Integrator handles the final commit; implementers stage but do NOT commit, do NOT push.
- Final integrated PR opens against `develop` (not `main`).

## Out of scope (deferred — flag in `**Not done:**` stanzas if relevant)

- Siblings audit for `DownloadStartDispatcher` / `DownloadAuthRetryHandler` / `BookButtonMapper`
  (memory `phase7_borrow_path_regressions_2026_05_14`).
- Final design copy for OPDS error message.
- Any refactor of `AudiobookSessionManager` beyond the two surgical sites in scope.
- ForgeOS contract regeneration for `MyBooks.json` if `DownloadStateManagerProtocol` grows
  a method (implementer flags; integrator runs `scripts/export-module-contracts.py`).

## Verification

Each implementer runs locally before staging:

```bash
# Mutation kill rate per their bucket:
python3 scripts/palace_mutate.py --file <file> --tests <TestClass> --diff-only

# Full verify-pr battery:
scripts/verify-pr.sh --quick

# Pre-release mutation enforcement (orchestrator runs before promote):
scripts/verify-pr.sh --quick --enforce-mutations
```

Orchestrator integration step runs `verify-pr.sh --quick --enforce-mutations` against
the merged diff before promoting through ForgeOS.
