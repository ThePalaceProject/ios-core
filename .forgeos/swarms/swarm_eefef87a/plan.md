---
name: swarm_eefef87a-plan
type: immutable
status: active
created: 2026-05-26T15:00:00Z
last_refresh: 2026-05-27
freshness_window: never
owners: [general]
description: "Swarm `swarm_eefef87a` — A+ Posture Push"
---

# Swarm `swarm_eefef87a` — A+ Posture Push

Four parallel improvements to close documented-not-closed structural risks from the engineering-posture review (`.forgeos/audits/phase7-synthesis-2026-05-26.md`).

## Goal

Take the engineering posture from "documented" to "closed" on four specific gaps:

1. Remove the residual `TPPUserAccount.sharedAccount()` fallback window that produces spurious login modals during library swaps mid-download (auth-critical).
2. Add a cross-vendor audiobook smoke gate to verify-pr.sh so any toolkit-touching PR has a fast regression net across all four vendor adapter types.
3. Audit and expand the critical-path mutation regex in verify-pr.sh — surface every borrow/download/DRM/auth file, codify in an ADR.
4. Pin Reader2 (Readium 3.x WKWebView, XCTest-invisible) dependency-call surface with contract snapshots.

## Modules

| Module | Domain | Files | Improvement |
|---|---|---|---|
| **A** — Accounts+MyBooks AccountId Threading | accounts | `Palace/Network/TPPNetworkExecutor.swift`, `Palace/MyBooks/MyBooksDownloadCenter.swift`, `Palace/MyBooks/DownloadStartCoordinator.swift`, `Palace/MyBooks/DownloadStartDispatcher.swift`, `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift` (Test 8), NEW `PalaceTests/MyBooks/MyBooksDownloadCenterAccountIdThreadingTests.swift` | #1 |
| **B** — Audiobook Cross-Vendor Smoke | audiobook | NEW `PalaceTests/Audiobooks/CrossVendorSmokeTests.swift` | #2 (Swift) |
| **C** — Tooling | general | MOD `scripts/verify-pr.sh`, NEW `docs/architecture/critical-path-mutation-coverage.md` | #2 (script) + #3 |
| **D** — Reader2 Contract Snapshots | reader | NEW `PalaceTests/Contract/Reader2BookmarkContractTests.swift`, NEW `PalaceTests/Contract/Reader2PositionResumeContractTests.swift`, NEW `__Snapshots__/...`, possibly small Reader2 production seams | #4 |

## Parallelism plan

All four modules are file-disjoint and can run in parallel. Sequencing constraint: **Module C's verify-pr.sh patch references Module B's test class by name (`AudiobookCrossVendorSmokeTests`).** Module B must land its file before Module C's gate is verified end-to-end. Module C can be written in parallel — the verify-pr.sh edit references the class name as a string, not a Swift import.

Integrator merges in this order (all into the swarm branch, single PR per module against `develop`):
1. Module A (auth-critical — gets the most reviewer attention; longest review cycle)
2. Module B (smoke tests — production-side risk is zero)
3. Module C (gate — verifies after B lands; if Module C is reviewed first, the gate test must use a deferred-name-lookup pattern)
4. Module D (contract snapshots — independent of A/B/C)

## Risks

### Module A — auth-critical (FLAG)

This is the single highest-risk module of the four. The `currentUserAccount` resolver already has Option 2 (lastKnownCurrentUserAccount) deployed. Module A layers Option 1 on top. The risks are:

- **Capture-too-late** — if accountId is captured after some MBDC method has already read `currentUserAccount`, the window is still open. The implementer must verify the capture happens at the FIRST production line of `startDownloadAsync`.
- **Stale capture** — a long-running download against a swapped-away library may sit on bytes that need bearer-token refresh from the swapped-away account. The captured-id model means those refreshes go to the correctly captured (now-non-current) account. This is intentional, but it's a behavior change from current code — flag in the PR description.
- **`@objc class func bearerAuthorized`** — this is a class method (not instance), which is why it uses `AppContainer.production()`. Adding an instance pathway means call sites need to know which `TPPNetworkExecutor` instance they're talking to. Verify the call site in `DownloadStartDispatcher.swift:182` has the executor in scope (it does — `self.networkExecutor` or similar).
- **Round-trip wiring test is mandatory** — `feedback_round_trip_wiring_tests.md` says Test 8 must exercise A→nil→A→B through the production seam. If the implementer writes a setter-shortcut test, the wiring isn't proved. Architect must verify this on review.

### Module B — vendor coverage

The `reference_audiobook_toolkit_risk_profile.md` memory says four vendors share player infrastructure. Active code has four adapters: LCP, BearerToken, OpenAccess, LocalFile. Findaway is referenced in the memory pin but is not an active vendor in `Palace/Audiobooks/Vendors/`. Module B's contract documents this so the implementer doesn't go hunting for a missing adapter.

### Module C — regex blast radius

The mutation regex change is high-blast-radius: tightening it makes ALL critical-path PRs harder to merge. Loosening it silently regresses the posture audit. The ADR is the maintenance contract — without it, future authors will trim files from the regex without realizing what they're giving up.

### Module D — Reader2 testability

Reader2 production files may need seams. Each added seam is a public API risk. The contract bounds seams to three files and requires `// testability seam` comments + transcript documentation. Architect must review every seam in PR review.

## Acceptance criteria (summary; per-module detail in contracts)

- A: Test 8 exists + passes; 8 MBDC fallback sites threaded; no new `.shared` reads; `bearerAuthorized(request:accountId:)` exists.
- B: 4 smoke cases for LCP/BearerToken/OpenAccess/LocalFile, all green, aggregate <10s.
- C: regex updated, ADR written with verification commands + output, audiobook smoke gate added.
- D: 6 contract-snapshot scenarios across 2 files, all JSONs committed, second-run-passes.
- Global: `scripts/verify-pr.sh --quick` passes; no edits to don't-touch lists per module.

## Companion documents

- ADR (new): `docs/architecture/critical-path-mutation-coverage.md` (Module C)
- Audit: `.forgeos/audits/phase7-synthesis-2026-05-26.md` (source of the four risks)
- Memory pins (load-bearing):
  - `reference_tpp_user_account_migration_retro.md` (Module A)
  - `reference_audiobook_toolkit_risk_profile.md` (Module B)
  - `feedback_round_trip_wiring_tests.md` (Module A)
  - `feedback_worktree_palace_setup.md` (all modules — every implementer runs from a worktree)
