---
name: resolve test pollution lint failures retire ReachabilityTests flake
author: maurice.carrier
created: 2026-06-04
type: fix
risk: standard
---

# Resolve test-pollution lint failures + retire the ReachabilityTests CI flake

## Motivation

Consolidating the stacked test-pollution PRs (#1037/#1038/#1039) onto current
`develop` surfaced four real CI failures distinct from the long-standing
`ReachabilityTests` timing flake:

- `AppContainerIsolationLintTests` flagged residue the A-shrink (56→23) left
  behind — `DRMAdversarialTests` (G1 migrated most of it but missed the
  live-account check) plus three PP-4161 files PR #1034 added to develop after
  the swarm's base and never exempted.
- `AccountsManagerIsolationLintTests` flagged the SUT's own unit test, which
  must construct `AccountsManager(defaults:)` directly.
- `TearDownRequiredLintTests` self-tripped on `ReachabilityTests` comments.

The `ReachabilityTests` flake itself has blocked six PRs and is a false
invariant (cached async `isConnected` vs synchronous `isConnectedToNetwork()`),
so it is retired rather than re-admin-merged.

## Claims (what the diff WILL deliver)

1. Extract the `getDetailedConnectivityStatus()` status→tuple mapping into a
   pure, deterministically-testable `Reachability.detailedStatus(...)` seam
   (behavior-preserving) and replace the flaky `ReachabilityTests` timing test
   with 10 deterministic branch tests that read no live network and no
   production singleton.
2. Remove `ReachabilityTests.swift` from `A-deferred-files.txt` (now clean).
3. Add the four genuinely-deferred files (`DRMAdversarialTests`,
   `StreamingReaderPresentationContractTests`, `BookDetailViewModelTests`,
   `BookCellModelStreamingHTMLTests`) to `A-deferred-files.txt` as
   pending-migration residue.
4. Whitelist `AccountsManagerTests.swift` in `AccountsManagerIsolationLintTests`.
5. Reword `ReachabilityTests` comments to drop the literal polluter substring.

## Anti-claims (what the diff WILL NOT do)

- Does NOT change observable production behavior — the PalaceNetwork change is a
  pure extraction; the same tuple is returned for the same path state.
- Does NOT migrate the four deferred files' `production()` usage — that is a
  follow-up gated on SUT dependency-injection for the navigation-coordinator hub.
- Does NOT add new public API.
- Does NOT touch any other production code.

## Files in scope

- `Palace/Packages/PalaceNetwork/Sources/PalaceNetwork/Reachability.swift`
- `PalaceTests/Network/ReachabilityTests.swift`
- `PalaceTests/MetaTests/AccountsManagerIsolationLintTests.swift`
- `.forgeos/swarms/swarm_47883816/A-deferred-files.txt`

## Verification

- `ReachabilityTests` 10/10, `AppContainerIsolationLintTests` 5/5,
  `TearDownRequiredLintTests` 5/5, `AccountsManagerIsolationLintTests` 2/2,
  `TPPUserAccountIsolationLintTests` 3/3 on iPhone 16 Pro — TEST SUCCEEDED.

## Out-of-scope

- Real `makeTestAppContainer()` migration of the four deferred files.
- The CarPlay / AudiobookLoader full-suite isolation flakes (pass in isolation).
