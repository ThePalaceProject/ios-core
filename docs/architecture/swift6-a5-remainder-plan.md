# Swift 6 Phase A.5 remainder — execution plan (31 app-target warnings)

<!-- audit-verified -->
Status: **ready to execute.** Branch `swift6/apptarget-registry-sweep-a5` (off develop
`210f5713a`). Drafted 2026-07-01 after the DRM slice (PR #1155) cleared the first 11 of
the 42 A.4-measured app-target `targeted` warnings. This plan covers the remaining **31**.
No local DRM build — CI Unit Tests is the warning gate. `SWIFT_VERSION` stays 5.0.

User decision (2026-07-01): do **both chunks sequentially in one branch** (registry/age
residue first, then the non-critical sweep), then re-run A.4 to confirm 0 (modulo A.6).

## ⚠️ Shared-type cascades — map these FIRST (architect Phase 0)
The 31 warnings are NOT independent. Fix the shared types once and several sites clear:
- **`AccountDetails` → Sendable** clears `Account+State.swift:51` (LoadState assoc. value)
  AND `TPPAgeCheck.swift:113`. Decide: make `AccountDetails` Sendable-honest vs `@preconcurrency`.
- **`AccountsManager` → Sendable** is needed by `TriageBotFactory.swift:104`. `AccountsManager`
  is a large shared singleton-ish type — this may be its own mini-slice or `@preconcurrency`.
  Do NOT blindly `@unchecked` it; check its mutable state first (like TPPUserAccount).
- **`TPPUserAccountProvider`** capture in `TPPAgeCheck:114` — may ride on the TPPUserAccount
  Sendable work already landed in #1155 (verify after #1155 merges).
- **`TPPReadiumBookmark` → Sendable** clears `TPPReaderBookmarksBusinessLogic:144,151`.

## Chunk 1 — Registry / age cascade residue (13 warnings) — RIGOROUS (critical-ish)
`TPPBookRegistry` is the book-state source of truth → architect + SoD, air-tight tests.
- `Book/Models/BookRegistrySync.swift` ×9 (:359,361,369,371,387,389×2,504,506) — `capture of
  'setState'/'completion'/'errorDocument' in @Sendable closure`. These are the sync-completion
  closures writing registry state. Fix pattern: the closures cross into a `@Sendable` network
  callback; either make the captured closure types `@Sendable`-compatible or hop through the
  registry's main-actor boundary. Mirror the LCPPDFOpenProgress approach if a recorder pattern fits.
- `Book/Models/TPPBookRegistry.swift:313` — `'token' mutated after capture by sendable closure`
  (capture an immutable copy before the closure, like DLNavigator below).
- `Book/Models/TPPBookCoverRegistry.swift:76` — remove the now-unnecessary `nonisolated(unsafe)`
  (trivial; the type is already Sendable).
- `Accounts/AgeCheck/TPPAgeCheck.swift` ×4 (:108,113,114,115) — `capture of completion/
  accountDetails/userAccountProvider in @Sendable closure`. Depends on AccountDetails +
  TPPUserAccountProvider Sendable (cascade above).

## Chunk 2 — Non-critical sweep (18 warnings) — /swarm module-implementers
Group by module; each is a small fix-by-isolation. Most are "capture in @Sendable closure".
- `AppInfrastructure/AppContainer.swift:481` — main-actor `.shared` from nonisolated → nonisolated accessor or hop.
- `AppInfrastructure/DLNavigator.swift:107` — `'token' mutated after capture` → capture immutable copy.
- `AppInfrastructure/FirebaseManager.swift:147` — `capture of self (FirebaseManager)` → make Sendable or hop.
- `Accounts/Library/Account+State.swift:51` — AccountDetails Sendable (cascade).
- `CarPlay/CarPlayImageProvider.swift:67` — `capture of completion` → Sendable/box.
- `CarPlay/CarPlayTemplateManager.swift:96` — main-actor `remove` from nonisolated → MainActor hop (NOT assumeIsolated in deinit — see plan gotchas).
- `CatalogUI/ViewModels/CatalogViewModel.swift:229` — `CatalogRepositoryProtocol` can't exit main actor → isolation.
- `OPDS/TPPOPDSFeed+Networking.swift:164,195` — `capture of errorDict (NSDictionary?)` → capture Sendable copy.
- `PDF/Views/PDFThumbnailStrip.swift:132` — `capture of provider (PDFKitThumbnailProvider)` → Sendable.
- `Reader2/Bookmarks/AudiobookBookmarkBusinessLogic.swift:193,198` — `capture of completion` → box/Sendable.
- `Reader2/BusinessLogic/TPPReaderBookmarksBusinessLogic.swift:144,151` — TPPReadiumBookmark Sendable (cascade).
- `Reader2/UI/TPPEPUBViewController.swift:926` — `capture of self (Self)` → weak/hop.
- `Support/TriageBotFactory.swift:104` — AccountsManager Sendable (cascade — may be its own slice).

## Execution order
1. **Architect Phase 0** — map the 4 shared-type cascades (AccountDetails, AccountsManager,
   TPPUserAccountProvider, TPPReadiumBookmark); decide Sendable-honest vs @preconcurrency for each.
   AccountsManager is the risky one (audit its mutable state first).
2. **Chunk 1 rigorous** — registry/age residue (13), architect + qa SoD + mutation on BookRegistrySync.
3. **Chunk 2 swarm** — non-critical sweep (18), module-implementers against contracts, integrate + forge-review.
4. **Re-run A.4** — `gh workflow run "Unit Tests" --ref <branch-or-develop>`, grep the 31 sites → 0.
5. **A.6 decision** — the 37 PalaceTests-target warnings: is the test target in Phase A scope?

## Deferred follow-ups (from Chunk 1 SoD-qa review, cs_b8969e9a)
Not Swift-6 warnings — testability debt surfaced while landing Chunk 1. Track separately:
1. **Widen `BookRegistrySync.opdsFeedServiceProvider`** from `() -> OPDSFeedService`
   (concrete actor) to `() -> OPDSFeedFetching`, and add the
   `fetchFeed(from:resetCache:)` overload to the `OPDSFeedFetching` protocol. Then
   inject the existing `feedFetcher` mock in `BookRegistrySyncTests` to cover the
   three uncovered `sync()` carrier branches deterministically: feed-fetch-failure
   errorDocument forward (BookRegistrySync:417-419), `.synced` success forward
   (:534-536), awaitReady-catch forward (:389-391). Its own reviewed change —
   provider-type + protocol surface on a critical path; do NOT fold into a warning slice.
2. **Confirm the keychain-gated carrier test runs (not skips) in CI.**
   `test_sync_whenNotSyncing_withCredentialsAndNoLoansUrl_resolvesToLoaded` is
   currently the SINGLE exerciser of the `SyncCallbacks` carrier path; if the CI lane
   lacks the keychain entitlement, `KeychainAvailability.skipIfUnavailable()` drops
   carrier coverage to zero silently.

## Gotchas (from the DRM slice + plan §5)
- No local DRM build — CI is the gate. Fix-by-isolation only; never `nonisolated(unsafe)` (except
  REMOVING the unnecessary one at TPPBookCoverRegistry:76), no bare `@unchecked Sendable`.
- Critical-path files (TPPBookRegistry, AccountsManager) require the pre-push review refs — the SoD
  classifier blocks the author from self-recording agent reviews; plan for a genuine 2nd-party review
  or an authorized `SKIP_CRITICAL_PATH_REVIEW=1` push (as PR #1155 did).
- Re-verify TPPUserAccountProvider / TPPUserAccount cascades AFTER #1155 merges.
