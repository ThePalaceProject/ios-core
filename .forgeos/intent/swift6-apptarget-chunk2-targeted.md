---
name: swift6-apptarget-chunk2-targeted
created: 2026-07-01
author: Maurice Carrier
branch: swift6/apptarget-registry-sweep-a5
initiative: Swift 6 app-target Phase A.5 — Chunk 2 non-critical sweep (swarm swarm_afec67f0)
priority: standard
---

# Intent: Swift 6 `targeted` strict-concurrency — Chunk 2 non-critical sweep

## Context

Phase A.5 remainder Chunk 2 (`docs/architecture/swift6-a5-remainder-plan.md`),
run as swarm `swarm_afec67f0` (5 parallel module-implementers against the
architect's contracts under `.forgeos/swarms/swarm_afec67f0/`). Branch rebased
onto develop@8e0017066 (includes #1155 → `TPPUserAccount` Sendable). Fix by
ISOLATION only — no behavior change. `SWIFT_VERSION` stays 5.0; warnings under
`targeted`. No local DRM build — CI "Unit Tests" is the warning gate; local
verification is a noDRM compile (clean on all 14 files) + the mechanical
detectors. ForgeOS enforcement OFF; SoD review kept local.

## Claims

- Eliminates ~21 `targeted` capture warnings across 8 modules (AppInfrastructure,
  Accounts, CarPlay, OPDS, PDF, CatalogUI, PalaceCatalog, Reader2) by isolation:
  - **Carrier boxes** (documented `@unchecked Sendable`, mirroring
    `ImageCompletionBox`): CarPlayImageProvider, TPPOPDSFeed+Networking
    (`SendableOPDSErrorDictionary`), PDFThumbnailStrip, TPPAgeCheck
    (`AgeCheckCallbacks`), Reader2 (`ReadiumBookmarkBox`, `TrackPositionCompletionBox`).
  - **`@unchecked Sendable` on a type** with a documented mutable-state audit:
    `AccountDetails` (Account.swift), `FirebaseManager`.
  - **isolate-at-site**: `TriageBotFactory.currentPalaceFields()` reads
    `currentAccount` inside the `MainActor.run` and returns Sendable `PalaceFields`
    (AccountsManager left untouched — NOT made Sendable).
  - **ObserverTokenBox mirror**: `DLNavigator.callOnce`.
  - **`MainActor.assumeIsolated`**: `AppContainer` builder's `UserAccountPublisher.shared`
    read (composition root, already-main-thread; mirrors the in-file `authCoordinator`
    hop).
  - **protocol `: Sendable`**: `CatalogRepositoryProtocol` (clears CatalogViewModel;
    sole conformer already `@unchecked Sendable`).
  - **`@MainActor` method**: `TPPEPUBViewController.applyDecorationsAsync`.
  - **capture hoist**: `CatalogViewModel` prefetch reads `repository` on main
    before the detached task.

## Anti-claims

- Does NOT make `AccountsManager` or `TPPReadiumBookmark` Sendable (both retain
  genuinely-racy mutable state — isolated at the capture sites instead).
- Does NOT change observable behavior — isolation/capture mechanism only.
- Does NOT touch the Chunk 1 files
  (`Book/Models/{BookRegistrySync,TPPBookRegistry,TPPBookCoverRegistry}.swift`).
- Does NOT use `nonisolated(unsafe)` or bare (undocumented) `@unchecked Sendable`.
- Does NOT call any `mcp__forgeos__*` tools.

## Files in scope (14)

- Palace/AppInfrastructure/{AppContainer,DLNavigator,FirebaseManager}.swift
- Palace/Accounts/Library/Account.swift, Palace/Accounts/AgeCheck/TPPAgeCheck.swift
- Palace/Support/TriageBotFactory.swift
- Palace/CarPlay/CarPlayImageProvider.swift
- Palace/OPDS/TPPOPDSFeed+Networking.swift, Palace/PDF/Views/PDFThumbnailStrip.swift
- Palace/CatalogUI/ViewModels/CatalogViewModel.swift,
  Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/CatalogRepository.swift
- Palace/Reader2/{BusinessLogic/TPPReaderBookmarksBusinessLogic,Bookmarks/AudiobookBookmarkBusinessLogic,UI/TPPEPUBViewController}.swift

## Deferred (scope-reduction, accepted)

- `CarPlayTemplateManager.swift:96` (deinit → `@MainActor remove(_:)`): the observer
  is `self` (no self-capture-free hop), the removal is load-bearing (prevents
  disconnect/reconnect crashes, so cannot be dropped), and the proper fix (a
  `@MainActor` teardown wired from `CarPlaySceneDelegate.didDisconnect`) is a
  behavior change out of this isolation-only slice's scope. Deferred to a dedicated
  CarPlay slice (which the existing code comment already references). 21 of 22
  Chunk-2 sites landed.
