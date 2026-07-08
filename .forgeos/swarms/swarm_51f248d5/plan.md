## Plan summary (for `.forgeos/swarms/swarm_51f248d5/plan.md`)

```markdown
# Swarm swarm_51f248d5 — 3.2.0 close-out wave 2

**Task:** auth-adjacent items unblocked by PR #1018 merge:
- (A) Split `.detailsFailed(.accountNotFound)` enum case (eviction-marker vs real-failure)
- (B) Full SwiftUI refactor of SignInModal presentation (Option A — keep TPPSignInBusinessLogic underneath)
- (C) Apply permanent fixes from `.forgeos/wall-failures/2026-05-28-cs847892e8-arch1.md` (process + docs only)

**Base branch:** `swarm/swarm_c8fcab76-scaffold` — STACKED ON PR #1020 (audiobook first-open hang). Anti-scope for all modules:
`Palace/Audiobooks/`, the audiobook tests under that umbrella, and the `worktree-refactor-saml-auth` continuation files. `ios-audiobooktoolkit/` is read-only.

## Modules

| ID | Name | Rigor | Owner files (top-level) | Parallelism |
|----|------|-------|-------------------------|-------------|
| A | AccountNotFound enum split | critical-path | `Palace/Accounts/` | Parallel — no overlap with B or C |
| B | SignInModal SwiftUI refactor | critical-path | `Palace/SignInLogic/`, 12 call sites | Parallel — overlap-free with A & C (B does NOT modify `Palace/Accounts/`; A's adjustments to `TPPSignInBusinessLogic.swift:286` are NOT in A's scope — that site only matches `.detailsLoaded`, which is preserved; if A breaks API B sees compile errors at integration time) |
| C | Apply arch1 fixes | standard | `CLAUDE.md`, two skill SKILL.md files, two wall-failure docs | Parallel — zero Swift code |

**Overlap-free guarantee:** A owns `Palace/Accounts/Library/Account+State.swift`, `Palace/Accounts/Library/AccountStateStore.swift`, `Palace/Accounts/Library/AccountsManager.swift`, `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift`. B owns `Palace/SignInLogic/SignInModalView.swift`, `Palace/SignInLogic/SignInModalPresenter+SignInModalPresenting.swift`, and the 12 call-site files listed in B's contract. C owns 5 markdown files — zero Swift overlap.

A's existing `.detailsLoaded` consumer at `Palace/SignInLogic/TPPSignInBusinessLogic.swift:286` is read-only for A (only the `.accountNotFound` write/read pair is being refactored, not the `.detailsLoaded` shape).

## Highest risks

1. **A — cascading consumer changes from enum split.** Risk: a switch-statement consumer pattern-matches `.detailsFailed(.accountNotFound)` and silently becomes wrong when the eviction marker moves to its own case. **Mitigation:** the split is to ADD a new case to `Account.LoadState` (e.g. `.detailsEvicted(.libraryDeselected(uuid: String))`), NOT to repurpose `.detailsFailed`. Existing switch arms that match `.detailsFailed(.accountNotFound)` keep their literal meaning (genuine 404). Compile-time exhaustiveness on `Account.LoadState` will force every `switch` over `loadState` to consider the new `.detailsEvicted` case — the compiler is the safety net.
2. **B — SwiftUI presentation lifecycle edge cases.** Risk: present → background → re-foreground → user-cancel-mid-auth races, especially against the existing `isPresenting` static guard. **Mitigation:** B's contract REQUIRES three new lifecycle tests (foregrounded-after-background, sheet-style dismissal, user-cancel-mid-auth) AND a contract test pinning the SwiftUI presentation contract (one sheet at a time, never two).
3. **A — round-trip wiring tests must not regress (Test 7).** Risk: the canonical eviction-marker test at `AccountsManagerStateMachineWiringTests.swift::testDriveCurrentAccountAuthDoc_staleAccountNotFoundMarker_redrives` is the regression net for the original bug. A MUST adapt it to the new case shape AND it must still pass.
4. **C — recursive application.** Risk: Module C is adding the very clause that (in principle) the wave-2 implementers should already be obeying. **Decision:** Module C is process/docs only. Modules A and B implement under the NEW clause (their contracts include the boundary clause inline so they get it from the contract, not from CLAUDE.md). C's edits are reference text for FUTURE swarms.

## Acceptance criteria

- A: enum split lands; old test 7 adapts to the new shape and stays green; new semantics-pinning tests for `.detailsEvicted` and `.detailsFailed(.accountNotFound)` pass; verify-pr.sh --quick green; mutation kill-rate ≥80% diff-scoped on `Palace/Accounts/Library/AccountsManager.swift`.
- B: 12 call sites updated; existing `SignInModalPredicateTests` + `SignInModalSAMLOIDCTests` pass unchanged; 3 new SwiftUI-lifecycle tests added and pass; no new `.shared` reads; mutation kill-rate ≥80% on `SignInModalView.swift`.
- C: 5 doc files updated verbatim per wall-failure entry; `derived-improvements.md` row appended; status `applied` in the wall-failure entry.

## Anti-scope (universal)

- `Palace/Audiobooks/`, `PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift`, `Palace/Audiobooks/PlaybackReadinessGate.swift`, `Palace/Audiobooks/AudiobookSessionManager.swift` — PR #1020 territory.
- `worktree-refactor-saml-auth` continuation files — dedicated session.
- `ios-audiobooktoolkit/` — high-risk submodule.
- `Palace/ErrorHandling/PalaceError.swift` `.accountNotFound` case (different enum — out of scope).
```

---
