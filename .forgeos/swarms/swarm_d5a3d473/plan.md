---
name: swarm_d5a3d473-plan
type: immutable
status: active
created: 2026-05-19T00:00:00Z
last_refresh: 2026-05-19
freshness_window: never
owners: [general]
description: Phase 1 Plan — Singleton Reduction (swarm_d5a3d473)
---

# Phase 1 Plan — Singleton Reduction (swarm_d5a3d473)

**Initiative:** 3.2.0 singleton-reduction sweep · **Base:** develop
**Feature branch:** swarm/swarm_d5a3d473-scaffold (becomes bundled-PR branch)
**Status:** triaged

## Goal

Two tracks bundled in one swarm, fully parallel-safe (disjoint file scopes).

**Track A — Image-loading consolidation (~28 prod refs across 10 files):**
Three overlapping singletons (`ImageCache.shared`, `TPPBookCoverRegistry.shared`, `TPPBookCoverRegistryBridge.shared`) split the same responsibility — fetching, decoding, caching, and bridging book cover/thumbnail images to Obj-C. Consolidate behind a single `ImageLoading` protocol injected through `AppContainer`. Architectural cleanup (removes duplicate responsibility); not just a `.shared` sweep. Production behavior identical; new tests for the unified protocol; existing `MockImageCache` survives.

**Track B — Test-side singleton sweep (~50+ test refs across 3 singletons):**
Add init-injection ctors + protocol seams to `AudiobookFileLogger`, `PersistentLogger` (SPM package), and `DeviceSpecificErrorMonitor`. Production `.shared` accessors stay; non-test call sites unchanged. The 3 affected test classes are refactored to construct directly via the new ctor, eliminating cross-test global-state pollution.

After this swarm:
- 338 → ~310 prod `.shared` references (~28 fewer in Track A scope; AccountsManager/AudiobookSessionManager/TPPDeveloperSettings 7 deferred refs remain on `.shared` pending PR #956 and swarm_81b5099e merge).
- ~50+ test `.shared` references dropped in Track B.
- Net effect: `.shared` count down ~28 prod / ~50 test; one architectural duplication (`TPPBookCoverRegistry` vs `ImageCache`) collapsed.

(The original task brief estimates "338 → ~270 prod + drop ~65 test." The architect's grep-verified count lands at ~28 prod (after off-limits filter cut 7 refs we'd love to migrate but can't without colliding with #956 and swarm_81b5099e) and ~50 test. We adjust the headline accordingly: ~28 prod migrated this swarm; the ~7 deferred prod refs land in a follow-up swarm after PR #956 and PR #963 merge.)

## Modules

| Module | LOC | Files | Parallelism |
|---|---|---|---|
| ImageLoading-Consolidation | ~220 prod + ~180 test | 10 prod edited + 2 new prod + 3 new test | **Parallel** |
| Logging-TestSeams | ~110 prod + ~280 test | 3 prod edited + 3 test rewritten | **Parallel** |

Total: 2 implementers, 13 prod files + 6 test files, ~330 LOC prod + ~460 LOC test.

## Sequencing

Both implementers branch from `swarm/swarm_d5a3d473-scaffold` (already at `origin/develop` HEAD) and run in parallel. File scopes are DISJOINT — verified:

- Track A files: `Palace/Utilities/ImageCache/*`, `Palace/Book/Models/TPP{Book,BookCoverRegistry,BookRegistry}*.swift`, `Palace/Book/Models/TPPBook+Presentation.swift`, `Palace/AppInfrastructure/{AppContainer,TPPAppDelegate}.swift`, `Palace/CarPlay/CarPlayImageProvider.swift`, `Palace/Settings/Debug/DebugSettings.swift`, `Palace/OPDS2/Models/OPDS2PublicationExtended.swift`, `Palace/MyBooks/MyBooks/BookListView.swift`.
- Track B files: `Palace/Logging/AudiobookFileLogger.swift`, `Palace/Packages/PalaceLogging/Sources/PalaceLogging/PersistentLogger.swift`, `Palace/Utilities/DeviceSpecificErrorMonitor.swift`, `PalaceTests/Logging/{AudiobookFileLogger,PersistentLogger,DeviceSpecificErrorMonitor}Tests.swift`.

No overlap. Two implementers run simultaneously, integrate independently.

## Risks

1. **Cross-package SPM edit (PersistentLogger).** `Palace/Packages/PalaceLogging/Sources/PalaceLogging/PersistentLogger.swift` is in an SPM package consumed by the host app. New `public init` + `public protocol` go in; package compile-test must pass. Mitigation: verify `Palace/Packages/PalaceLogging/Package.swift` requires no change (it doesn't — automatic public export); compile via `xcodebuild -project Palace.xcodeproj -scheme Palace …` which exercises the SPM dep.

2. **Concurrent PR #956 (test capability uplift).** Touches `TPPDeveloperSettingsTableViewController.swift` (which holds both Track A and Track B singletons) and `AudiobookSessionManagerShutdownTests.swift`. Both files are OFF-LIMITS to this swarm. Implementers must NOT migrate the 7 `.shared` references in those two files; they're deferred to a follow-up swarm once #956 merges.

3. **Concurrent PR #963 (Bucket A migration).** Touches `Palace/Audiobooks/AudiobookSessionManager.swift` (which has 2 `TPPBookCoverRegistry.shared` references). Off-limits. Defer those 2 to the same follow-up swarm.

4. **Concurrent swarm_81b5099e.** Owns `Palace/Accounts/Library/` (4 `ImageCache.shared` references in `AccountsManager.swift`), all of `SignInLogic/`, `Accounts/AgeCheck/`, `Notifications/NotificationService.swift`. The swarm_81b5099e frozen set is reproduced verbatim in each contract's OFF-LIMITS section.

5. **TPPBook ↔ TPPBookCoverRegistry Obj-C interop.** `TPPBookCoverRegistryBridge` exists specifically to give Obj-C callers a synchronous-completion-handler shape. `ImageLoader` must preserve that surface (the `completion:` overloads in the protocol). If the implementer can't get the weak-book-reference safety pattern right under the new shape, the bridge file may stay as a thin shim that calls into `ImageLoader` (delete the duplicate logic, keep the public `@objcMembers` surface). Documented in the contract.

6. **Mutation regression risk on Track B.** Today's tests catch some mutants via shared global state (the persisted log file across tests). New isolated tests must compensate with stronger assertions (concurrent writes, rotation, clear-removes-rotated). Pin ≥50% kill rate per file.

## Key decisions recorded

- **Singleton stays in Track B.** Production `.shared` accessors on the 3 Track B types are NOT removed (it's a test-seam exercise, not a singleton-deletion). Only the test classes change. This preserves binary + behavior compat for `Log.swift`, `ErrorLogExporter.swift`, `AudiobookDataManager.swift`, etc.
- **Track A is architectural cleanup, not just a sweep.** The duplicate responsibility between `ImageCache` (disk-layer) and `TPPBookCoverRegistry` (network + decode actor) collapses into one `ImageLoader` type, with `ImageCache` retained internally as the disk byte cache. The Obj-C bridge collapses into a `completion:` overload on the new protocol.
- **`ImageLoader.production` is NOT a fresh `.shared`.** It's a deprecated-annotated static accessor that reads `AppContainer.production().imageLoader`. Used only where threading the container through is impractical (Obj-C-reachable TPPBook factories). New call sites use `@Environment(\.appContainer).imageLoader`.
- **`MockImageCache` survives.** The `ImageCacheType` protocol stays (still the disk layer). New `MockImageLoader` conforms to the new `ImageLoading` protocol.
- **PR #956 + PR #963 + swarm_81b5099e files are non-negotiably off-limits.** This is the precedent set by swarm_81b5099e's SignIn-AgeCheck-Notifications contract and the new Phase 0 swarm discipline. Implementers do NOT speculatively migrate "easy" `.shared` refs in those files.

## Acceptance criteria (per implementer)

- `xcodebuild -project Palace.xcodeproj -scheme Palace -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build` green.
- Palace-noDRM also green.
- All existing PalaceTests pass.
- New tests per the contract pass.
- Mutation gate per contract (warn-only Track A; ≥50% Track B).
- No edits to files outside the implementer's declared `files_scope`.
- `scripts/verify-pr.sh --quick` passes.

## Acceptance criteria (swarm-level)

- 28 production `.shared` references migrated (verified by `grep -rn "ImageCache\.shared\|TPPBookCoverRegistry\.shared\|TPPBookCoverRegistryBridge\.shared" Palace --include="*.swift" --include="*.m"` returning only off-limits sites).
- 50+ test `.shared` references replaced with init-injection across the 3 logging test files (verified by `grep -c "\.shared" PalaceTests/Logging/{AudiobookFileLogger,PersistentLogger,DeviceSpecificErrorMonitor}Tests.swift` returning 0 each).
- `forge-review` SoD verdict green on both modules.
- `verify-pr.sh --quick` passes on the merged scaffold branch.
- One bundled PR opened against `develop` with both module deltas + transcripts.
