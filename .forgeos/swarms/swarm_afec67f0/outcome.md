# Swarm outcome — swarm_afec67f0 (Swift 6 targeted, Chunk 2 non-critical sweep)

**Status:** complete. **Result:** 21 of 22 `targeted` warnings landed by isolation; 1 deferred.

## Modules / implementers (5, parallel)
| Module | Files | Result |
|---|---|---|
| AppInfrastructure | AppContainer, DLNavigator, FirebaseManager | ✅ 3 sites |
| Accounts | Account, TPPAgeCheck, TriageBotFactory (Account+State cascade-cleared) | ✅ |
| CarPlay | CarPlayImageProvider | ✅ Site 1; **Site 2 (deinit) DEFERRED** |
| OPDS-PDF-Catalog | TPPOPDSFeed+Networking, PDFThumbnailStrip, CatalogViewModel, CatalogRepository (pkg) | ✅ 4 files |
| Reader2 | TPPReaderBookmarksBusinessLogic, AudiobookBookmarkBusinessLogic, TPPEPUBViewController | ✅ 3 files |

## Cascade decisions (architect)
- **AccountDetails** → documented `@unchecked Sendable` (forced — `LoadState` already Sendable). Audit: all state `let` / UserDefaults; 5 `url*` vars write-once in `init` (setURL has zero external callers), vended into Sendable `LoadState.detailsLoaded` after init. Honest.
- **AccountsManager** → NOT made Sendable (27+ mutable vars). Isolated at the single `TriageBotFactory.currentPalaceFields()` site (read inside `MainActor.run`, return Sendable `PalaceFields`).
- **TPPReadiumBookmark** → NOT made Sendable (10 mutable vars). Carrier box (`ReadiumBookmarkBox`) at the two BusinessLogic capture sites.
- **CatalogRepositoryProtocol** → `: Sendable` (sole prod conformer already `@unchecked Sendable`; 2 test mocks are `@MainActor final class` → implicitly Sendable).

## Verification
- noDRM compile: **clean on all 14 files** (only pre-existing unrelated `AudiobookSessionManager` FEATURE_OVERDRIVE error).
- Detectors: blast-radius / superpartner-spectrum / adjacency-staleness all exit 0.
- **Local SoD architect review: APPROVE-WITH-NITS** (all carrier-box invariants verified true; both `@unchecked Sendable` types honest; AppContainer `assumeIsolated` safe; no rippled/remaining warnings). Kept local (ForgeOS OFF).
- CI "Unit Tests" (workflow_dispatch on the branch) is the authoritative warning gate — pending.

## Deferrals & follow-ups
1. **DEFERRED — CarPlayTemplateManager:96 (deinit):** observer is `self` (no self-capture-free hop); removal is load-bearing (prevents disconnect/reconnect crashes); proper fix (a `@MainActor` teardown from `CarPlaySceneDelegate.didDisconnect`) is a behavior change out of this isolation-only slice. → dedicated CarPlay slice (existing code comment already references it).
2. **FOLLOW-UP (N2, pre-existing) — Reader2 `TPPReadiumBookmark` cross-thread aliasing:** the boxed bookmark is also in the `bookmarks` array while `annotationId` is mutated on the network-completion thread (TPPReaderBookmarksBusinessLogic.swift:114/165). Pre-existing latent race, NOT introduced or worsened by this isolation-only boxing; a future Reader2 concurrency pass should close it.

## Adaptations from stock /swarm skill
- No ForgeOS API (enforcement OFF) — changeset/evidence/reviews kept local.
- No DRM-build-gated gates (verify-pr/mutation/xcresult) — no local DRM build; noDRM compile + CI is the verification.
- Ran in an isolated git worktree (`swarm/swarm_afec67f0-work` off swift6 HEAD 7a794b248) because another session holds a staged index in the main checkout.
