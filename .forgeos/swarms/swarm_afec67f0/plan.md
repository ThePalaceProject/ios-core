# Swarm `swarm_afec67f0` — Swift 6 `targeted` concurrency, Phase A.5 Chunk 2 (non-critical sweep)

**Architect triage — 2026-07-01.** Branch `swift6/apptarget-registry-sweep-a5`
(rebased onto develop@8e0017066; includes #1155 → `TPPUserAccount` now
`@unchecked Sendable`). HEAD at triage: `7a794b248`.

## Goal
Drive the remaining ~22 app-target `targeted` strict-concurrency warnings to
**zero** across ~8 modules, **fix-by-ISOLATION only**. No behavior changes —
isolation / capture mechanism only. `SWIFT_VERSION` stays 5.0. Verification is
noDRM compile at integration (orchestrator) + CI "Unit Tests" warning run; **no
local DRM build, no verify-pr/mutation/xcresult** for implementers.

## Hard constraints (encoded in every contract)
- Fix by **ISOLATION only**. NEVER `nonisolated(unsafe)`. NO **bare**
  `@unchecked Sendable` — a **documented** `@unchecked Sendable` carrier with a
  real, stated invariant (mirroring `ImageCompletionBox` / `SyncCallbacks` /
  `SendableErrorDocument` / `ObserverTokenBox` from Chunk 1) IS allowed.
- No behavior changes. Timing, dispatch queue, priority, and observable effects
  must be preserved exactly.
- Do **not** touch `Palace/Book/Models/{BookRegistrySync,TPPBookRegistry,
  TPPBookCoverRegistry}.swift` (Chunk 1, already landed).
- Do **not** run verify-pr.sh / palace_mutate.py / xcresult (need a DRM build we
  don't have). Deliverable evidence per site: (a) the site + the exact fix,
  (b) which established pattern it mirrors, (c) any behavior risk.
- Do **not** call any `mcp__forgeos__*` tools (ForgeOS is OFF for this swarm).

## Reference patterns to mirror (Chunk 1 + precedent)
- **`ImageCompletionBox`** — `Palace/Utilities/ImageCache/ImageLoaderImpl.swift:11`
  — canonical documented `@unchecked Sendable` carrier for a non-Sendable
  completion handler only ever invoked on the main actor.
- **`SyncCallbacks` / `SendableErrorDocument`** — bottom of
  `Palace/Book/Models/BookRegistrySync.swift` — carrier structs for
  non-Sendable closures / `[AnyHashable: Any]?` write-once-then-read payloads.
- **`ObserverTokenBox`** — `Palace/Book/Models/TPPBookRegistry.swift:58` — box
  for a self-removing observer's `var token` that a `@Sendable` block references
  without capturing a mutated `var`.
- **`TPPAgeCheck: @unchecked Sendable`** — `Palace/Accounts/AgeCheck/TPPAgeCheck.swift:25`
  — precedent for a class whose mutable state is serial-queue/lock-guarded.

## The 3 cascade decisions

### 1. `AccountDetails` → **documented `@unchecked Sendable`** (FORCED, not optional)
`Account.LoadState` is **already declared `Sendable`** (Account+State.swift:47)
with a `.detailsLoaded(AccountDetails)` associated value. There is **no
isolate-at-site option** — stripping `Sendable` from `LoadState` would break
`awaitReady()` / `stateStream` cross-actor delivery (an architecture/behavior
regression). AccountDetails' only mutable state is 5 `fileprivate var url*: URL?`
fields that are **write-once during account parse** (`setURL(_:forLicense:)`,
Account.swift:455, right after construction) plus UserDefaults-backed computed
setters (`eulaIsAccepted` / `syncPermissionGranted` / `userAboveAgeLimit`) that
delegate to the internally-thread-safe `UserDefaults`. It is effectively an
immutable value-holder once vended into `.detailsLoaded`. This mirrors #1155's
`TPPUserAccount` decision exactly. **Clears** `Account+State.swift:51` AND the
`accountDetails` capture in `TPPAgeCheck`.

### 2. `AccountsManager` → **do NOT make Sendable; isolate at the TriageBotFactory site**
`AccountsManager` has 27+ mutable `var` fields (`accountSet`, `accountSets`,
`accountByUUID`, `loadingCompletionHandlers`, `inflightAuthDocFetches`,
`backgroundFetchTask`, `_trackedCrawlTasks`, …) — a large live singleton;
`@unchecked Sendable` would be a genuine race waiver. Its only Chunk-2 consumer,
`TriageBotFactory.currentPalaceFields()`, already does
`await MainActor.run { AppContainer.production().accountsManager }` and then
reads `manager.currentAccount?.name/.uuid` **off** the main actor. Fix: move the
field reads **inside** the existing `MainActor.run` block and return only the
already-`Sendable` `PalaceFields`. Strictly **more correct** (currentAccount is
main-actor state) and requires **zero** change to AccountsManager. **Clears**
`TriageBotFactory.swift:104`.

### 3. `TPPReadiumBookmark` → **do NOT make Sendable; isolate at the BusinessLogic capture sites**
`TPPReadiumBookmark` has 10 genuinely-mutable `var` properties and is mutated
across a concurrency boundary (`bookmark.annotationId` set in
`TPPAnnotations.postBookmark`'s completion, TPPReaderBookmarksBusinessLogic.swift:158)
while instances also live in the `bookmarks` array — real shared mutable state;
`@unchecked Sendable` at the type level would waive a real race and ripple
`Sendable` onto every bookmark call site. Fix: wrap the captured `bookmark` in a
documented `@unchecked Sendable` carrier box at the two `postBookmark` capture
sites (invariant: only read / added-to-registry on the main actor inside the
`MainActor.run` blocks). Mirror `ImageCompletionBox`. **Clears**
`TPPReaderBookmarksBusinessLogic.swift:144,151`. `TPPReadiumBookmark.swift` itself
is **NOT modified**.

### Bonus type decision — `CatalogRepositoryProtocol` → **add `: Sendable`** (clean)
The sole conformer `CatalogRepository` is **already `@unchecked Sendable`**
(CatalogRepository.swift:22). The protocol is a stateless 3-async-method service.
Adding `: Sendable` is the honest, minimal fix — no `@Sendable`-closure ripple,
no behavior change — and unblocks capturing the repository across the detached
prefetch task in `CatalogViewModel.swift:229`. (Small protocol, not a big shared
mutable type — this is isolate-at-type done right, not the AccountsManager
anti-pattern.)

## Module partition (5 disjoint contracts, overlap-free)

| Contract | Files (each in exactly ONE contract) | Sites |
|---|---|---|
| **AppInfrastructure** | AppContainer.swift, DLNavigator.swift, FirebaseManager.swift | 481, 107, 147 |
| **Accounts** | Account.swift, Account+State.swift, AgeCheck/TPPAgeCheck.swift, Support/TriageBotFactory.swift | AccountDetails cascade + 51 + AgeCheck ×3–4 + 104 |
| **CarPlay** | CarPlayImageProvider.swift, CarPlayTemplateManager.swift | 67, 96 (deinit — HIGH RISK) |
| **OPDS-PDF-Catalog** | TPPOPDSFeed+Networking.swift, PDF/Views/PDFThumbnailStrip.swift, CatalogUI/ViewModels/CatalogViewModel.swift, PalaceCatalog/CatalogRepository.swift | 164/195, 132, 229 |
| **Reader2** | BusinessLogic/TPPReaderBookmarksBusinessLogic.swift, Bookmarks/AudiobookBookmarkBusinessLogic.swift, UI/TPPEPUBViewController.swift | 144/151, 193/198, 926 |

`TriageBotFactory` is folded into **Accounts** because it rides the
AccountsManager cascade decision and touches account state. `TPPReadiumBookmark.swift`
is deliberately NOT in any contract (decision 3 fixes at the call site).

## Parallelism plan
All 5 contracts are file-disjoint and cascade-decisions are pre-decided, so all
5 implementers run **fully in parallel**. Ordering note: the **Accounts**
contract owns the `AccountDetails: @unchecked Sendable` change that clears both
`Account+State:51` and the `TPPAgeCheck` accountDetails capture — both live in
the Accounts contract, so there is **no cross-contract dependency**. No
integration barrier between contracts.

## Risks
1. **CarPlayTemplateManager.swift:96 (deinit) — HIGHEST RISK.** Main-actor
   `CPNowPlayingTemplate.remove(self)` from a nonisolated `deinit`. `assumeIsolated`
   is BANNED here (deinit not guaranteed on main → fatalError risk); capturing
   `self` in an escaping `Task` from deinit is a resurrection hazard. If the
   implementer cannot find a self-capture-free, behavior-preserving MainActor
   hop, they MUST **STOP and file a scope-deferral** (do not reach for
   assumeIsolated / nonisolated(unsafe)). See the CarPlay contract.
2. **AppContainer.swift:481.** `UserAccountPublisher.shared` is `@MainActor`;
   `production()` is nonisolated. Prescribed fix uses `MainActor.assumeIsolated`
   (LEGAL here — production() is a main-thread composition root, unlike a deinit).
   Implementer must confirm `production()` call sites are all main-thread.
3. **A.4 line drift.** All line numbers are the A.4 snapshot; locate by symbol.
   `TPPAgeCheck` may emit the capture warning at more/fewer than the cited 4
   lines (108/113/114/115) — the implementer clears **every**
   capture-of-non-Sendable-in-`@Sendable`-closure in the verify path, not just
   the cited lines.
4. **Package edit.** `CatalogRepositoryProtocol` lives in the `PalaceCatalog`
   SPM package; adding `: Sendable` is in-workspace and safe (sole conformer
   already Sendable) but crosses the app/package boundary — call it out in the
   diff.

## Post-integration
Re-run A.4: `gh workflow run "Unit Tests" --ref swift6/apptarget-registry-sweep-a5`,
grep the sites → expect 0. Then the A.6 decision (37 PalaceTests-target warnings).
