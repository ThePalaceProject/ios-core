# Palace iOS — Target Architecture & Decomposition Plan (ADR draft)

**Status:** proposed · **Author:** architect agent, 2026-07-23 · **Extends:** `docs/architecture/architectural-triad.md` (Phases 6–7, which this document supersedes with a complete map) · **Vocabulary:** this doc reuses the triad's terms — AppContainer composition root, `Store<State,Action,Environment>`, reducer-as-pure-function, contract-snapshot tests, "load-bearing on day 1."

---

<!-- audit-verified: the five 3a extraction PRs (#1361/#1363/#1366/#1367/#1368) + #1360 were
     authored, SoD-reviewed, and merged to develop this session (2026-07-31); F-016 is the
     currentUserAccount nil-window / PR #822 spurious-sign-in-modal class documented in
     verification-checklist.md §5/§7 and preserved verbatim by the 3a-5 AccountCredentialResolver. -->

## Wave 3 / 3a — `AccountsManager` decomposition: COMPLETE (2026-07-31)

The `AccountsManager` god-class decomposition finished at **five injected in-target
collaborators** (2383 → 915 LOC, −62%), all merged to `develop`, each moving a cohesive
state + I/O + lock cluster out of the hub:

- `AccountRegistryCache` (3a-1, #1361) — on-disk catalog cache (FileManager I/O).
- `AccountRegistryStore` (3a-2, #1363) — registry state + the concurrent `accountSetsLock` barrier + the `accountByUUID` index.
- `AuthDocumentLoader` (3a-3, #1366) — auth-doc fetch state machine + the single-flight map/lock.
- `AccountRegistryLoader` (3a-4, #1367) — catalog load orchestration + owned-crawl registry + drain.
- `AccountCredentialResolver` (3a-5, #1368) — per-account `TPPUserAccount` cache/lock + the F-016 ride-out.

Preceded by the `AccountNetworking` seam (#1360, inverting the last concrete `TPPNetworkExecutor` type edge).

**3a-6 `CurrentAccountStore` — deliberately NOT extracted (STOP decision, 2026-07-31).** The
`currentAccount` get/set switch pipeline (~61 executable LOC; almost no state of its own —
`currentAccountId` is computed over `UserDefaults`, `isAccountSwitching` is one `Bool`) is the
**irreducible composition-root orchestration spine**, not a god-class remnant. Extracting it
would require an ~11–13 provider-closure fan-out (larger than 3a-4's) that conserves coupling
while adding an indirection hop; the `@objc` `currentAccount`/`account(_:)` witnesses cannot move
(the hub must keep forwarding facades regardless); and packageability is **already satisfied** —
the S1/S3 seams inverted every external singleton reach, so the setter now names only
`PalaceAccounts`-internal collaborators + `NotificationCenter` + `TPPErrorLogger`. A composition
root that names its collaborators to sequence an account switch is correct, not a smell. The hub
is at its irreducible core (~374 executable LOC, ~90 of it DEBUG-only test seams). **Do not
re-litigate 3a-6.** The `PalaceAccounts` SwiftPM package move is the next, separate step when desired.

---

## 1. Current-state review

### What is healthy (the target pattern is proven in-repo, not hypothetical)

- **Seven live SPM packages** under `Palace/Packages/` — PalaceAuth, PalaceCatalog, PalaceKeychain, PalaceLogging, PalaceNetwork, PalaceReadingPosition, PalaceTriageBot. They are load-bearing (imported by `AppContainer.swift` itself), Swift-6-mode, and **cycle-free by construction**: SwiftPM rejects cyclic package graphs at manifest-resolution time. Their internal dependency DAG is already the embryo of the target: `PalaceAuth → {PalaceLogging, PalaceNetwork, PalaceCatalog}`, `PalaceCatalog → {PalaceLogging, PalaceNetwork}`, `PalaceNetwork → PalaceLogging`. None of the 24 ledger cycles touches a package. This is the single most important empirical fact in the codebase: **where a compile-time boundary exists, the cycle problem is already solved.**
- **AppContainer is a real composition root** (`Palace/AppInfrastructure/AppContainer.swift`): ~20 `let` services + ~12 lazy `@MainActor` cached seams, explicit hand-threaded construction in `_buildCachedAppContainer()` that documents every historical init-cycle deadlock, test seams (`withSignInModalSheetPresenter`, `_resetForTesting`, `testExecutorProtocolClasses`). The mechanism to replace every `.shared` read exists; adoption is the remaining work, not invention.
- **Reducers extracted on the critical paths**: `BorrowReducer` (integrated into `BookDetailViewModel` via snapshot/apply), `HoldsReducer`, `AuthReducer` (in the PalaceAuth package, awaiting integration), `AccountStateMachine`. `Store.swift` (~70 LOC, `Effect`-returning pure reduce) is the settled shape.
- **Contract-snapshot safety net exists and is populated**: `PalaceTests/Contract/` has `CallLog.swift` + `ContractSnapshot.swift` and **11 snapshot suites** — BorrowOperation, BookReturnService, DownloadStartCoordinator, BorrowReducer, AudiobookPositionAdapter, PositionWriter, three Reader2 suites, SideloadImport, StreamingReaderPresentation. Extraction can be gated on "snapshot unchanged."
- **MyBooksDownloadCenter is further decomposed than its LOC suggests.** `Palace/MyBooks/` already contains ~25 extracted collaborators (BackgroundDownloadHandler, DownloadQueueOrchestrator, DownloadThrottlingService, DownloadTaskPersistence, DownloadStartDispatcher/Coordinator, TokenRefreshInterceptor delegate wiring, BorrowErrorPresenter, CredentialPromptCoordinator, BookReturnService, LCPFulfillmentHandler, OverdriveDownloadHandler, DiskBudgetManager, …). MBDC's tail (lines ~1809–2155) is fourteen `*Delegate` conformances that mostly forward. The remaining god-mass is the URLSession delegate plumbing, background-session identity/reconciliation (Reliability WS-A), and error-announcement glue — a **boundary problem, not a carving problem**.
- **A declared layer model already exists** in `tools/ledger/ledger-config.json`: layers `[Infrastructure, Domain, Presentation, Application, Tests]` with allowed edges `Application→{Presentation,Domain}`, `Presentation→Domain`, `Domain→Infrastructure` — plus 32 componentRoots. The ledger CI trend gate is live (0.9.7). The target below is expressed in exactly this layer vocabulary so the existing gate enforces it without re-tooling.

### What is broken

- **Folders are not modules.** ~567 Swift files in the app target share one namespace. `Palace/Book/` freely references `AccountsManager`; `Palace/Settings/` freely references `TPPUserAccount`; nothing stops it. That mutual visibility IS the 183-edge / 24-cycle graph. All cycles funnel through five hub folders (Accounts, Book, Settings, Audiobooks, Logging) precisely because those folders host the types everyone reaches for (`Account`, `TPPBook`, `TPPSettings`, `TPPErrorLogger`) *and* host high-level orchestrators that reach back out. The hub folders mix layers internally — that internal mixing is what each cycle's two directions actually are (verified per-cycle in §3b).
- **The god-orchestrators are accreting, not shrinking.** 19-day deltas: AudiobookSessionManager +529 (+24%), AccountsManager +549 (+33%), MyBooksDownloadCenter +328 (+18%). Every reliability fix (F-011 readiness gates, PP-4542 position resolve, WS-A durable downloads, CP-D1 launch hydration) lands *inside* the hub because the hub is where the seams are. Without a ratchet, decomposition is bailing a leaking boat.
- **39 declared singletons are the coupling substrate.** The triad cut `.shared` call sites 732→~564, but the highest-fan-in ambient reaches remain: TPPKeychain.shared (40), RemoteFeatureFlags.shared (32), FirebaseManager.shared (25), UserAccountPublisher.shared (16), ImageCache.shared (16), NotificationService.shared (12), AccountStateStore.shared (8). Notably, **several of these already have AppContainer seams that consumers bypass** (`imageCache`, `userAccountPublisher`, `bookRegistry` are container members; `AppContainer._buildCachedAppContainer()` itself still reads `ImageCache.shared` and `UserAccountPublisher.shared` to build them). Even `appRatingService` construction inside AppContainer reaches for `RemoteFeatureFlags.shared` / `FirebaseManager.shared` via closures. The pattern exists; enforcement doesn't.
- **`AppContainer.production()` is itself used as a service locator** — e.g. `Palace/ErrorHandling/ErrorDetail.swift` and `Palace/Book/UI/TPPProblemReportViewController.swift` call `AppContainer.production().accountsManager` in default args / bodies. That's a `.shared` read with extra steps: it preserves the ambient-reach graph and defeats testability the same way. The target must treat `AppContainer.production()` outside composition roots as a violation, not a win.
- **Known debt from the triad remains open**: AuthReducer not integrated into TPPSignInBusinessLogic (gated on characterization tests that were never written — the class had 0 dedicated tests at triad time); MBDC de-singletonized but body intact; the AppContainer static-cache cells (`_audiobookSession`, `_catalogRepository`, …) are themselves process-wide singletons with hand-maintained `_resetForTesting()` bookkeeping — a recurring source of the systemic test pollution.

**One-sentence diagnosis:** the architecture has the right *mechanisms* (packages, container, reducers, contracts) but the wrong *defaults* — inside the monolithic target, reaching sideways is free, so every fix accretes onto a hub; the fix is to make sideways reach a compile error by promoting the hub folders' lower halves into SPM packages with an enforced DAG, leaving thin app-target shells.

---

## 2. Target architecture

### 2.1 The destination in one paragraph

Palace becomes a **thin app target over a layered SPM package DAG**. Every *domain* concern (models, registries, engines, flow logic) lives in a package; the app target retains only Application-layer composition (AppContainer, app/scene delegates), Presentation (SwiftUI/UIKit screens, ViewModels), and the **irreducible Infrastructure adapters that cannot leave** (Adobe RMSDK / LCP DRM binaries, Firebase SDK wiring, CarPlay). Packages depend only downward; the app target depends on packages; **no package ever imports the app target** — which SwiftPM enforces mechanically, making every one of today's cycles a compile error rather than a lint warning. Ambient state dies with the folders: every current `.shared` read becomes an AppContainer `let`/lazy seam injected by constructor, and the container stops being callable as a locator outside composition roots (CI-gated).

### 2.2 Layers and packages

Names follow the established `Palace*` convention; layer names follow `ledger-config.json`. **(exists)** = already in `Palace/Packages/`. **(new)** = created by this plan. Every new package must be load-bearing on day 1 (≥1 app-target import at the PR that creates it) — the triad's anti-PalaceFoundation rule.

```
LAYER 3 — Application (app target only)
  Palace app target: TPPAppDelegate, SceneDelegate, AppContainer,
  ModuleComposition, CarPlay templates, Firebase/DRM/notification wiring,
  developer settings
        │ imports everything below
LAYER 2 — Presentation (app target now; packages optional/later)
  SwiftUI screens + ViewModels + reducer integrations:
  CatalogUI, Book/UI, MyBooks UI, Settings UI, Holds UI, Reader2/PDF UI,
  Audiobook player shells   (+ external: ios-audiobooktoolkit, PalaceUIKit)
        │
LAYER 1 — Domain (packages)
  PalaceBookModel   (new)  TPPBook, registry records, book-state enums,
                           acquisition/format model
  PalaceBookRegistry(new)  TPPBookRegistry engine (account-scoped book state)
  PalaceAccounts    (new)  Account, AccountsManager (decomposed), auth-doc
                           loading, AccountStateStore, UserAccountPublisher
  PalaceDownloads   (new)  download engine: queue orchestration, throttling,
                           task persistence, background reconciliation,
                           progress publishing, borrow orchestration core
  PalaceAuth        (exists) AuthCoordinator, AuthReducer, flow engines
                           (grows: sign-in flow logic from TPPSignInBusinessLogic)
  PalaceCatalog     (exists) OPDS2 models, catalog API/repository
  PalaceReadingPosition (exists)
  PalaceAudiobookSession (new, conditional — see §3a caveat)
        │
LAYER 0 — Infrastructure (packages + irreducible app-target adapters)
  PalaceNetwork     (exists)   PalaceLogging (exists)   PalaceKeychain (exists)
  PalacePreferences (new)  TPPSettings key-value store (no domain knowledge)
  PalaceFeatureFlags(new)  FeatureFlagProviding protocol + typed flag surface
                           (impl stays app target — Firebase Remote Config)
  App-target-only adapters (permanent): AdobeDRMService/LCP (private binaries,
  FEATURE_DRM_CONNECTOR), FirebaseManager (SDK), NotificationService (FCM +
  UNUserNotificationCenter), ImageCache (candidate to package later)
```

### 2.3 The enforced DAG

Package manifests declare exactly these dependencies (SwiftPM rejects anything cyclic; anything not listed is unimportable):

```
PalaceLogging          → (nothing)
PalacePreferences      → (nothing)
PalaceFeatureFlags     → (nothing)
PalaceKeychain         → (nothing)                        [as today]
PalaceNetwork          → PalaceLogging                    [as today]
PalaceCatalog          → PalaceLogging, PalaceNetwork, PalaceFeatureFlags
PalaceBookModel        → PalaceLogging                    (models only — near-leaf)
PalaceBookRegistry     → PalaceBookModel, PalaceCatalog, PalaceLogging
                         [as shipped in Wave 2b — deviates from this ADR's
                         original DAG, which named PalacePreferences instead
                         of PalaceCatalog: the extracted cluster (TPPBookRegistry
                         + BookRegistryStore/Sync + BookmarkManager +
                         RegistryFileRecovery) has zero TPPSettings references,
                         so PalacePreferences was dropped; it DOES need
                         PalaceCatalog for TPPOPDSFeed/TPPOPDSEntry + the
                         OPDSFeedFetching seam, which already live there
                         (PalaceBookModel already depends on PalaceCatalog, so
                         this stays layer-clean). See
                         Palace/Packages/PalaceBookRegistry/Package.swift.]
PalaceAuth             → PalaceLogging, PalaceNetwork, PalaceCatalog,
                         PalaceKeychain                   [+Keychain vs today]
PalaceAccounts         → PalaceAuth, PalaceCatalog, PalaceNetwork,
                         PalacePreferences, PalaceKeychain, PalaceLogging
PalaceReadingPosition  → (as today)
PalaceDownloads        → PalaceBookModel, PalaceBookRegistry, PalaceNetwork,
                         PalaceAuth (AuthCoordinator surface), PalaceLogging
PalaceAudiobookSession → PalaceBookModel, PalaceReadingPosition,
                         PalacePreferences, PalaceLogging (+ toolkit, see caveat)
App target             → all of the above
```

Key inversions that make this acyclic (each is a protocol defined *in the lower package*, implemented/injected *from above* — the pattern PalaceAuth already uses with `CoordinatorAccountProvider` / `AuthDecisionRecording`, and PalaceCatalog with `FeatureFlagProvider`):

- **PalaceBookRegistry must not know PalaceAccounts.** Today `TPPBookRegistry.init(accountsManager:imageLoader:)` takes the whole AccountsManager. Target: `init(accountScope: AccountScopeProviding, …)` where `AccountScopeProviding` (`currentAccountID`, `accountDidChange` publisher) is a protocol in PalaceBookRegistry; the app target adapts AccountsManager to it. This single inversion is what keeps Book/Accounts permanently acyclic.
- **PalaceDownloads must not know DRM.** Fulfillment dispatch is `FulfillmentHandling` protocols declared in PalaceDownloads; Adobe/LCP/Overdrive handlers stay app-target and register at composition time (exactly how `drmAuthorizerProvider: () -> TPPDRMAuthorizing?` already works in AppContainer).
- **Nothing below Application knows Firebase.** Capability protocols (`CrashReporting`, `RemoteConfigProviding`, `PushMessaging`) live in the package that needs them; `FirebaseManager`/`NotificationService` implement them app-side. Precedent: `AuthDecisionRecording` in PalaceAuth wrapping Crashlytics.

### 2.4 How the compiler + CI enforce it

1. **SwiftPM (hard, structural):** cyclic package dependencies are a manifest-resolution error; a package cannot import the app target at all. Once code is in a package, the cycle it participated in *cannot recur*.
2. **Ledger layer gate (soft, for the shrinking app-target remainder):** the existing `layerRules` in `tools/ledger/ledger-config.json` keep policing the in-target folders during transition; each wave moves a folder's Domain half out and re-tags the remainder Presentation/Application. Name-inferred edges get a confidence tag (see §3b cycle 9).
3. **New ratchet gates (Wave 0):** god-class LOC freeze per file; `.shared`-read count monotone-down; `AppContainer.production()` call-site count outside an allowlist (composition roots, `@Environment` default, test bootstrap) monotone-down. All three are dumb greps — cheap, ungameable, wired into `verify-pr.sh` + a tooling-checks-style workflow per CLAUDE.md's "don't land a gate faster than you can verify it."

### 2.5 Why each root 2-cycle becomes structurally impossible (summary; full map in §3b)

The pattern in every case is the same: each cycle's two directions live at *different layers* inside the hub folders. The down-direction (X uses Y's *model/store*) becomes a package dependency; the up-direction (Y's *orchestrator/UI* reaches into X) either moves up to the app target with X, or inverts into a protocol the lower package declares. After that, the "cycle" is two one-way edges at different layers — which is just layering.

---

## 3. THE MAP

### 3a. God-classes → responsibility clusters → target homes

Clusters are read from the files' own `// MARK:` structure (verified against source this session). "Shell" = what remains in the app target after the wave completes.

#### 1. `Palace/Audiobooks/AudiobookSessionManager.swift` (2,761 LOC)

| Cluster (MARK-verified) | What it does | Target home |
|---|---|---|
| `AudiobookSessionState` + `AudiobookSessionError` (lines 20–78) | session lifecycle enum + error taxonomy | **PalaceAudiobookSession** (pure types) |
| Published state + internal state + external publishers (107–291) | `@Published` mirrors + Combine surface | **Shell** (`@MainActor ObservableObject` facade) |
| Public API + Manager Binding (526–1541) | open/close/play session; bind toolkit `AudiobookManager` | split: orchestration decision logic → `AudiobookOpenReducer` (pure, **PalaceAudiobookSession**); toolkit binding glue → **Shell** (toolkit types are Presentation-layer, see caveat) |
| Position resolve before play, PP-4542 (1542–1640) + position restoration helpers (1809–1992) | reconcile local/remote listening position | `AudiobookPositionResolver` → **PalaceAudiobookSession**, consuming **PalaceReadingPosition** (an adapter + contract test — `AudiobookPositionAdapterContractTests` — already exist) |
| Readiness-gate wiring, F-011 (265–291, 1641–1687) | injection points gating play until player ready | `PlaybackReadinessGate` type → **PalaceAudiobookSession**; injection stays Shell |
| LCP first-open reliable start, WS-5 (1688–1780) | DRM-specific start dance | **app target** (LCP = private DRM); behind `ProtectedPlaybackStarting` protocol declared in PalaceAudiobookSession |
| Chapter TOC normalization (1781–1808) | pure transform of toolkit TOC | `TOCNormalizer` pure func → **PalaceAudiobookSession** |
| Private methods (1993–end) | mixed glue | dissolves into the above during extraction |

**Shell:** `AudiobookSessionManager` remains as the `AudiobookSessionManaging` facade AppContainer already vends — publishes state, forwards to the reducer/services. Target ≤400 LOC.
**Caveat (honest):** the package form is **conditional** on `PalaceAudiobookToolkit` (git submodule, ledger-tagged Presentation, with a known layer violation) exposing a usable non-UI core API. If it doesn't by Wave 6, the same decomposition happens **in-target** (separate files, same seams) and the package is deferred. The decomposition is mapped either way; only its compile-enforcement is conditional.

#### 2. `Palace/Accounts/Library/AccountsManager.swift` (2,235 LOC)

| Cluster (MARK-verified) | What it does | Target home |
|---|---|---|
| Cache metadata + disk cache helpers (7–…, 1467–1604) | account-list disk cache, TTLs | `AccountRegistryCache` → **PalaceAccounts** |
| Config/state + thread-safe `accountSets` access (225–823) | registry state + `accountSetsLock` barrier | `AccountRegistryStore` (actor or lock-boxed store) → **PalaceAccounts** |
| Account retrieval (824–1016) | lookup by UUID/URL, current account | `AccountRegistryStore` + thin `CurrentAccountStore` (owns `currentAccount` + change publication, feeds `UserAccountPublisher`) → **PalaceAccounts** |
| Per-account user credentials (1017–1079) | credential resolution per account | `AccountCredentialResolver` → **PalaceAccounts**, storing via **PalaceKeychain** |
| Load logic, CP-D1 slim hydration + background crawl (1080–1466) | registry fetch, `loadCatalogs`, the background Task that pollutes tests | `AccountRegistryLoader` (explicitly owned, cancellable, injectable-scheduler) → **PalaceAccounts**. This is where `cancelAndDrainBackgroundWork` / `_drainAllLiveInstancesForTesting` become structured concurrency instead of drain heuristics |
| Auth-document fetch with state-machine wiring (1605–1786) | per-account auth doc fetch + `AccountStateStore` transitions | `AuthDocumentLoader` → **PalaceAccounts** (consumes AuthenticationDocument parsing already in **PalaceCatalog**; drives `AccountStateMachine`) |
| Parsing & notifying (1787–end) | feed parse + NotificationCenter posts | parse → loader; notification posts → typed Combine publishers on the store (Shell adapts to legacy NotificationCenter names during transition) |

**Shell:** `AccountsManager` becomes a facade composing the five collaborators, preserving its current API for the ~100 call sites; AppContainer constructs the pieces. Target ≤300 LOC. `Account` + `Account+profileDocument` move to PalaceAccounts with it (their `TPPErrorLogger` reads become the injected `ErrorReporting` protocol — see cycle 2).

#### 3. `Palace/MyBooks/MyBooksDownloadCenter.swift` (2,155 LOC)

| Cluster (MARK-verified) | What it does | Target home |
|---|---|---|
| URLSession delegate plumbing + download info map (1–~1000) | task↔book bookkeeping, delegate callbacks | `DownloadEngine` (URLSession broker + `DownloadTaskLifecycleService` + `DownloadTaskPersistence`, which already exist as files) → **PalaceDownloads** |
| Reliability WS-A: background session identity + completion handler + durable downloads + launch reconciliation (227–…, 1938–2155) | background-session adoption, INV-4/6/7 invariants | `BackgroundSessionReconciler` → **PalaceDownloads** (the WS-A invariant comments move with it as doc) |
| PP-4114 mid-flight network drop (1006–1135) | pause/resume on reachability | `DownloadRetryPolicy` → **PalaceDownloads** (consumes `Reachability` from **PalaceNetwork**) |
| Error announcements (1136–…) | a11y + user-facing error surfacing | **Shell** / DownloadAnnouncementService (already extracted, stays app target — Presentation concern) |
| Throttling + disk budget (1623–1808) | `DownloadThrottlingService` + `DiskBudgetManager` glue | services already exist as files → move both to **PalaceDownloads**; glue dissolves |
| 14 `*Delegate` conformances (1809–1937) | forwarding hub for the extracted collaborators | **Shell**: MBDC remains the app-target coordinator implementing these protocols, forwarding into the engine; DRM-specific delegates (LCPFulfillmentHandler, OverdriveDownloadHandler, AdobeDRMHandler) stay app target behind `FulfillmentHandling` |

**Shell:** MBDC keeps `MyBooksDownloadCenterProtocol` (already exists) as its surface; borrow entry-points route to `BorrowOperation`. Target ≤500 LOC. **This is the money path — its wave has the strictest test gate (§5).**

#### 4. `Palace/Book/UI/BookDetail/BookDetailViewModel.swift` (1,375 LOC)

| Cluster (MARK-verified) | What it does | Target home |
|---|---|---|
| Book state binding + BorrowReducer round-trip (268–502) | registry state → button state | **Shell** (this IS the VM's job; reducer already extracted) |
| Metadata hydration (521–590) + Related books / series row (21–43, 591–683) | fetch full OPDS entry, related-works lanes | `BookMetadataService` + `RelatedBooksService` → app-target **Domain-in-transit**, backed by **PalaceCatalog**'s repository (candidate to fold into PalaceCatalog once TPPBook lives in PalaceBookModel) |
| Button actions + Download/Return/Cancel (684–802, 894–948) | dispatch to downloadCenter/borrow | **Shell** (thin dispatch through injected `MyBooksDownloadCenterProtocol`) |
| Authentication helper (803–893) | reauth-then-retry glue | delete in place — route through **PalaceAuth**'s `AuthCoordinator` (this is exactly what AuthCoordinator was built for; the VM-local copy is pre-coordinator legacy) |
| Reading + Audiobook opening + Streaming HTML reader PP-4161 (949–1118) | open EPUB/PDF/audio/streaming | `BookOpenRouter` (app-target Application service; `BookService.swift` already holds the format-routing seam — consolidate there, see cycle 8) |
| Samples (1119–1176) | sample playback | **Shell** dispatch to existing `SamplePreviewManager` (AppContainer seam exists) |
| Error alerts (1177–…) + LCP streaming ext | present errors | **Shell** |

**Shell:** the VM itself, ≤600 LOC, purely `@Published` + reducer + dispatch. Note: BookDetailViewModel is *not* extracted to a package — VMs are Presentation and stay app-target; its *service work* is what moves.

#### 5. `Palace/SignInLogic/TPPSignInBusinessLogic.swift` (1,110 LOC)

| Cluster (MARK-verified) | What it does | Target home |
|---|---|---|
| Auth state machine (141–165) | drive `AccountStateMachine` | replaced by **AuthReducer integration** (reducer already lives in **PalaceAuth**; integration is the long-open triad debt, gated on characterization tests — §5) |
| OAuth/SAML/Clever info + SAML triad (166–277) | per-IdP endpoints, SAML helper/context/presenter | `OAuthFlow` / `SAMLFlow` / `CleverFlow` engine types → **PalaceAuth** (presenter part stays app-target Presentation) |
| Library accounts info (278–395) | account/authDoc lookups | thin reads via injected **PalaceAccounts** surfaces |
| Network requests logic (396–888) | token requests, profile doc, error mapping | `SignInRequestService` → **PalaceAuth** (uses **PalaceNetwork**; error mapping joins `AuthErrorClassifier` already in the package) |
| User account management (889–962) | persist credentials, update `TPPUserAccount` | `CredentialStore` → **PalaceAccounts** (+ **PalaceKeychain**) |
| Available-features checks (963–1054) | barcode/pin/card-creator gating | pure `AuthCapabilities` derivation → **PalaceAuth** |
| Adobe DRM activation skip logic (1055–end) | DRM activation decisions | **app target** (DRM), behind `DRMActivationPolicy` protocol declared in PalaceAuth |

**Shell:** the `@objc`-bridged class remains as facade while UIKit callers exist (it's ObjC-visible; full removal is gated on migrating those callers). Target ≤300 LOC. **Order is fixed: characterization tests → AuthReducer integration → engine extraction.** Anything else on a 0-dedicated-test critical path is reckless (triad decision log, still true).

#### 6. `Palace/MyBooks/BorrowOperation.swift` (989 LOC)

| Cluster (MARK-verified) | What it does | Target home |
|---|---|---|
| Pure helpers (144–260) + re-auth circuit breaker (99–143) | decision functions | **PalaceDownloads** (pure, trivially portable) |
| Dependencies + closure-injected seams + init (261–371) | DI surface | already clean — moves with the class |
| Borrow orchestration (372–569) | fetchBook → startDownload sequence | `BorrowOperation` core → **PalaceDownloads** (contract-pinned: `BorrowOperationContractTests` exists) |
| Auth-error handling + OIDC silent re-auth + coordinator-routed retry + sign-in-modal retry (570–…, 810–end) | 401/403 recovery ladder | routes through **PalaceAuth** `AuthCoordinator` (already injected); modal presentation stays app target via existing presenter protocols |
| Error presentation (754–809) | alert composition | **Shell** (`BorrowErrorPresenter` already a separate file, stays Presentation) |

**Honest assessment:** BorrowOperation is the *least* god-like of the six — closure seams, pure helpers, circuit breaker, contract tests all already in place. It moves largely intact in the PalaceDownloads wave; no internal decomposition needed. It's on this list for LOC, not for architecture debt.

### 3b. The 9 root 2-cycles → dissolving boundary

Each row names the *verified* code behind both directions (grepped this session) and the specific mechanism that removes it.

| # | Cycle | Down-direction (becomes package dep) | Back-direction (the edge that dies) | Dissolved by |
|---|---|---|---|---|
| 1 | **Book↔Accounts** | Accounts code touches book-registry sync surfaces (`TPPBookRegistry.syncAsync` refs in AccountsManager) | `Palace/Book/UI/*` reads `AccountsManager.currentAccount` (e.g. `TPPProblemReportViewController` via `AppContainer.production()`) | `TPPBook`/records → **PalaceBookModel**; registry → **PalaceBookRegistry** taking `AccountScopeProviding` (protocol in the registry package, adapter in app target) instead of AccountsManager. Book *UI* stays app-target Presentation and injects `CurrentAccountProviding`. Neither package can import the other's package — SwiftPM enforced |
| 2 | **Accounts↔ErrorHandling** | `Account+profileDocument`/`Account.swift` call `TPPErrorLogger.logError` | `ErrorDetail.swift` / `ProblemReportEmail.swift` default-arg `AppContainer.production().accountsManager` for device context | `ErrorReporting` protocol → **PalaceLogging** (beside the existing `CrashlyticsLogBridge`); PalaceAccounts logs through it; TPPErrorLogger implements it app-side. ErrorHandling's back-reach becomes a passed-in `DeviceContext` value (caller snapshots account info) — ErrorHandling stops importing Accounts entirely |
| 3 | **Logging↔Network** | `Palace/Network/TPPNetworkQueue` uses `Log.*` — legitimate, already acyclic as **PalaceNetwork→PalaceLogging** | `Palace/OPDS2/Service/TPPCirculationAnalytics.swift` uses `NetworkQueue`, `TPPNetworkExecutor`, `AccountsManager` | **File misfiled, not a real layering conflict.** TPPCirculationAnalytics is a circulation-domain network client, not logging. Move it out of `Palace/Logging/` (home: app-target Domain beside OPDS services; later PalaceCatalog). The folder-cycle vanishes with the move |
| 4 | **Accounts↔OPDS2** | Accounts parses feeds/auth docs (`CrawlableFeedAnalysis` uses `OPDS2Feed`/`OPDS2CatalogsFeed`) | `OPDSFeedService` reads `Account.LoadState`/`currentAccount?.loansUrl` (param already "widened from AccountsManager" per its own comment — inversion half-done) | OPDS2 models already live in **PalaceCatalog** (`OPDS2Feed.swift`, `OPDS2AuthenticationDocument.swift` in the package). Finish it: delete in-target duplicates, PalaceAccounts→PalaceCatalog one-way; OPDSFeedService keeps its protocol-widened account param (protocol declared feed-side) |
| 5 | **Accounts↔Settings** | `AccountsManager` stores `private let settings: TPPSettings` | `Palace/Settings/` UI (`AccountDetailViewModel`, `AdvancedSettingsView`, `TPPSettings+SE`) reads `AccountsManager`/`TPPUserAccount` | Split the Settings folder by layer: `TPPSettings` (pure prefs store) → **PalacePreferences** (Layer 0); Settings *screens* are Presentation and legitimately depend on PalaceAccounts one-way. The cycle existed only because store and screens shared a folder. (`TPPSettings+SE`'s hardcoded `AccountsManager.TPPAccountUUIDs` constant moves to PalaceAccounts as data) |
| 6 | **Settings↔Audiobooks** | `AudiobookSessionManager` stores `private let settings: TPPSettings` | `DeveloperSettingsViewModel.emailAudiobookLogs` + `AudiobookMailComposeDelegate` (dev tooling — the only Settings→Audiobooks reach) | Same PalacePreferences split kills the down-edge's folder-coupling; the dev-tools log-email consumes a `LogArchiveExporting` protocol (declared in **PalaceLogging**, implemented by the audiobook stack) instead of importing audiobook types. Thinnest cycle of the nine |
| 7 | **Book↔CatalogUI** | `CatalogState`/`CatalogSortService` operate on `[TPPBook]` | `BookDetailView` constructs `CatalogLaneMoreView` (series carousel / related lanes NavigationLinks) | `TPPBook` → **PalaceBookModel** makes CatalogUI→model a down-edge. The back-edge is Presentation-internal navigation: route via a destination-provider closure / `NavigationCoordinatorHub` (already an AppContainer member) instead of direct view construction. Both view folders stay app-target Presentation initially, so this one is gate-enforced (ledger) before it is compiler-enforced — flagged honestly |
| 8 | **PDF↔Book** | `TPPPDFDocumentMetadata` uses `TPPBook` + `TPPBookRegistryProvider` (already protocol-typed) | `Palace/Book/.../BookService.swift` routes to PDF opening (`PDFDocument(url:)` path) | PDF→**PalaceBookModel**/**PalaceBookRegistry** is a clean down-edge (it already consumes the registry via protocol). The back-edge dies by *relocating* `BookService`'s format-routing to the Application layer (`BookOpenRouter`, §3a-4): a router that knows all readers is composition, not Book-domain code |
| 9 | **TriageBotUI↔Palace** | — | — | **False positive** (name-based inference; PalaceTriageBot is an SPM package that cannot import the app target). Action: Wave 0 annotates it in ledger config as a known-false-positive / adds a confidence field for name-inferred edges, so the trend gate doesn't count it. No code change |

**Sanity check on completeness:** hubs named by the ledger = Accounts (cycles 1,2,4,5), Book (1,7,8), Settings (5,6), Audiobooks (6), Logging (3), Downloads (dissolved via PalaceDownloads even though it appears in longer paths, all of which thread the nine back-edges above). All 15 longer DFS cycles reuse these same back-edges, so dissolving the nine dissolves all 24.

### 3c. High-fan-in singletons → target home + injection mechanism

| Singleton (fan-in) | Today | Target home | Injection mechanism (the AppContainer seam that replaces `.shared`) |
|---|---|---|---|
| `TPPKeychain.shared` (40) | already in **PalaceKeychain** package; consumers still read `.shared`; `TPPKeychainManager` (app, ObjC) wraps it | stays PalaceKeychain | new `let keychain: TPPKeychain` (or `KeychainStoring` protocol) on AppContainer; credential paths reach it via `CredentialStore` (PalaceAccounts) rather than raw keychain reads. `.shared` retained solely for the ObjC bridge until those call sites die |
| `RemoteFeatureFlags.shared` (32) | app target `Palace/FeatureFlags/`; protocol precedent exists (`FeatureFlagProvider` in PalaceCatalog); AppContainer already closure-wraps it for `appRatingService` and hands it to `catalogAPI` | protocol + typed flag names → **PalaceFeatureFlags** (Layer 0); Firebase-Remote-Config-backed impl stays app target | `let featureFlags: FeatureFlagProviding` on AppContainer; packages declare only the flags they consume. Consolidates the per-package protocol copies into one |
| `FirebaseManager.shared` (25) | app target `AppInfrastructure/` | **permanent app-target Infrastructure** (Firebase SDK cannot go in packages that want to stay SDK-free) | split by capability: `CrashReporting`, `RemoteConfigProviding`, crash-free-probe closures — protocols declared in consuming packages, Firebase impls injected at composition (existing precedent: `AuthDecisionRecording`/`AuthDecisionRecorder`). No package ever names Firebase |
| `UserAccountPublisher.shared` (16) | app target `Accounts/User/`; **already an AppContainer `let`** — the builder itself still reads `.shared` to obtain it | **PalaceAccounts** (it is the account-change broadcast surface of `CurrentAccountStore`) | existing `container.userAccountPublisher` seam; migrate the 16 `.shared` reads to injected refs; builder constructs it instead of reading `.shared` |
| `ImageCache.shared` (16) | app target `Utilities/ImageCache/`; **already an AppContainer `let imageCache: ImageCacheType`** (protocol-typed); builder reads `.shared` | app target for now; optional `PalaceImaging` package later (zero cycle pressure — not in any cycle) | existing `container.imageCache` / `container.imageLoader`; migrate reads; builder constructs the instance |
| `NotificationService.shared` (12) | app target `Notifications/` — UNUserNotificationCenter + FCM (`MessagingDelegate`) | **permanent app-target Infrastructure** (Firebase Messaging + app-lifecycle delegate wiring) | `let notifications: NotificationScheduling` (narrow protocol: schedule/clear/badge) on AppContainer; the delegate-registration half stays wired in TPPAppDelegate as composition |
| `AccountStateStore.shared` (8) | app target `Accounts/Library/` (`public final class`, has `_resetAllForTesting`) | **PalaceAccounts** (state store beside `AccountStateMachine`) | `let accountStateStore: AccountStateStore` on AppContainer, constructed with the accounts graph, injected into `AuthDocumentLoader`/consumers; the test-resetter attaches to the container reset instead of a global |
| `TPPBookRegistry` (registry fan-in) | `.shared` killed in triad Phase 6.6; AppContainer constructs it and vends `bookRegistry: TPPBookRegistryProvider`; residual direct references remain | **PalaceBookRegistry** package | existing `container.bookRegistry` seam — already the pattern; the wave moves the type and inverts the AccountsManager constructor dep (`AccountScopeProviding`, §3b-1) |
| `UIApplication.shared` (79) | system | **out of scope by design** — platform shim (triad already exempts platform shims) | wrap only the few testability-relevant uses (badge count, open-URL) behind tiny protocols as touched; no campaign |

**Explicitly not-yet-mapped (findings, not hidden gaps):**
1. **The other ~31 declared singletons** below this fan-in tier (e.g. `AdobeDRMService.shared`, `DLNavigator.shared`, sim/debug helpers) are not individually mapped here. Disposition rule: each wave's checklist includes "any `.shared` in files the wave touches gets a container seam or a written exemption." A full 39-row census is a Wave 0 deliverable (one script run against `reference_god_class_candidates` data), not an ADR blocker.
2. **AppContainer's static lazy caches** (`_audiobookSession`, `_catalogRepository`, `_signInModalSheetPresenter`, …) are process-wide singletons wearing container clothes, each with hand-maintained `_resetForTesting` bookkeeping. Target: fold into instance `let`s as their construction-order constraints allow (several exist only to break init cycles that die when AccountsManager decomposes in Wave 3). Mapped as a Wave-3/6 side effect, not a standalone wave.
3. **`AppContainer.production()` as service locator** (default args in ErrorHandling, Book/UI, Settings, Logging): mapped to the Wave 0 ratchet (count monotone-down) + per-wave cleanup, since each occurrence dies naturally when its file gets constructor injection.

---

## 4. Sequenced plan

Ordering principle: **leaf-inward** — extract what the hubs depend ON before touching the hubs, so each hub wave finds its down-dependencies already package-shaped. Waves marked ∥ can run as parallel fleets (disjoint files); ⊸ must serialize.

### Wave 0 — Ratchet + census (1 PR-week; prerequisite for everything)
No extraction. Land the gates so the problem stops growing while the fleet works:
- **God-class LOC freeze:** script + CI check — the 6 files' line counts may not exceed a checked-in baseline (decreases auto-rebaseline). Fires in `verify-pr.sh` + PR workflow.
- **Coupling trend-down:** ledger avg-coupling + cycle-count thresholds pinned at current values (183 edges / 24 cycles), must be ≤ baseline per PR.
- **`.shared`-read + `AppContainer.production()`-locator counts** monotone-down (grep-based, allowlisted composition roots).
- **Ledger hygiene:** annotate TriageBotUI↔Palace as known-false-positive; add confidence tags for name-inferred edges.
- **Singleton census:** the full 39-row disposition table (mechanical; fills §3c gap 1).
- Per CLAUDE.md gate rules: each new detector ships with a pytest in `scripts/tests/`, hook-fixture wiring incl. clean-diff pass, and a zero-false-positive dry run.

### Wave 1 ∥ — Layer-0 leaves (3 independent lanes, parallel-safe: disjoint files)
- **1a `PalacePreferences`:** move `TPPSettings` (+`TPPSettings+SE` minus the AccountsManager constant, which stays behind) into a new leaf package. Consumers: AccountsManager, AudiobookSessionManager, Settings UI. *Pre-tests:* characterization of key round-trips (UserDefaults-backed). *Dissolves the down-halves of cycles 5 and 6.*
- **1b `PalaceFeatureFlags`:** protocol + typed flags package; consolidate `FeatureFlagProvider` (PalaceCatalog) into it; `let featureFlags` on AppContainer; migrate the 32 `.shared` reads. *Pre-tests:* none beyond compile + existing suites (protocol move).
- **1c misfiles + inversions:** move `TPPCirculationAnalytics` out of `Palace/Logging/` (cycle 3); `ErrorReporting` protocol into PalaceLogging + ErrorHandling `DeviceContext` inversion (cycle 2); `LogArchiveExporting` for dev-tools audiobook logs (cycle 6 back-edge). *Pre-tests:* snapshot the analytics request shape (1 contract test).
- **CI gate for all of Wave 1:** ledger shows cycles 2, 3, 5, 6 gone (24→~13 incl. their DFS echoes); new packages imported ≥1× (load-bearing rule).

### Wave 2 ⊸ — The keystone: `PalaceBookModel`, then `PalaceBookRegistry` (serial within, blocks 3/4/7)
- **2a `PalaceBookModel`:** `TPPBook`, `TPPBookRegistryRecord`, book-state/format enums, acquisition model. Near-leaf (→PalaceLogging only). Biggest mechanical churn (hundreds of import-free references become `import PalaceBookModel`) but semantically inert.
- **2b `PalaceBookRegistry`:** `TPPBookRegistry` moves; constructor inverted to `AccountScopeProviding` (§3b-1); app-target adapter over AccountsManager. `container.bookRegistry` unchanged for consumers.
- *Pre-tests:* **registry contract suite** (new — `TPPBookRegistryContractTests`: state-transition call order for add/update/sync/remove against a spy persistence layer; the CLAUDE.md contract-test guidance already names "BookRegistry mutation paths" as a candidate) + existing `TPPBookRegistryMigrationTests`.
- **CI gate:** cycles 1, 7, 8's model-directions dead; PDF/CatalogUI/Accounts compile against packages; layer gate re-tagged.

### Wave 3 ∥(a/b) after Wave 2 — the mutually-coupled hub pair (the careful part)
- **3a `PalaceAccounts`:** AccountsManager decomposition per §3a-2 (RegistryStore, RegistryLoader, RegistryCache, AuthDocumentLoader, CurrentAccountStore/CredentialResolver), `Account` types, `AccountStateStore`, `UserAccountPublisher`. Kills the background-crawl test-pollution root cause as a structured-concurrency rewrite of `loadCatalogs`.
- **3b `PalaceDownloads`:** DownloadEngine + WS-A reconciler + throttling/persistence collaborators + `BorrowOperation` per §3a-3/6; DRM handlers stay app-side behind `FulfillmentHandling`.
- **Parallelism ruling:** 3a and 3b are ∥ **only because Wave 2 already cut their mutual edge** (downloads reach accounts solely via `AuthCoordinator` (PalaceAuth, exists) + `AccountScopeProviding` (Wave 2)). If any new Accounts↔Downloads edge is found mid-wave, 3b serializes behind 3a — the wave brief must say so.
- *Pre-tests:* 3a — **AccountsManager characterization pack** (crawl happy-path/cancellation/drain, auth-doc state transitions against `AccountStateMachine`, disk-cache TTL) + `AuthDocumentLoader` contract test. 3b — existing `BorrowOperationContractTests`, `BookReturnServiceContractTests`, `DownloadStartCoordinatorContractTests` **must be green and re-recorded==identical post-move**; new `BackgroundReconciliationContractTests` (INV-4/6/7 pinned).
- **CI gate:** cycles 1, 4 fully dead; ledger cycle count ≤ the TriageBot false positive; money-path mutation kill-rate on moved files ≥ pre-move.

### Wave 4 ⊸ (after 3a) — Sign-in: tests → integrate → extract
Strictly ordered, critical path: **(i)** characterization tests for `TPPSignInBusinessLogic` (the open triad Phase-3 debt — ≥30 tests, every auth method's happy + error path); **(ii)** integrate `AuthReducer` (already in PalaceAuth) via the proven snapshot/apply pattern; **(iii)** extract flow engines + `SignInRequestService` + `AuthCapabilities` into PalaceAuth, `CredentialStore` into PalaceAccounts; DRM-activation stays app-side. Shell stays ObjC-visible.

### Wave 5 ∥ — Presentation slimming (parallel with Wave 4; disjoint files)
`BookDetailViewModel` service extraction per §3a-4 (MetadataService/RelatedBooksService, BookOpenRouter consolidation into the Application layer — closes cycle 8's back-edge; navigation inversion for cycle 7's back-edge). App-target refactor only, no new packages.

### Wave 6 — Audiobook session split (after 4; package conditional)
In-target decomposition per §3a-1 first (reducer, position resolver, readiness gate, TOC normalizer as separate injected files); `PalaceAudiobookSession` package **only if** the toolkit-API caveat resolves. Retire the `_audiobookSession`/`_playbackBootstrapper` static caches into container lets as construction order allows.

### Wave 7 — Sweep + declare
Remaining `.shared` census rows dispositioned; `AppContainer.production()` locator count → allowlist-only; ledger `componentRoots` updated to package-first; ratchet thresholds converted from "trend-down" to "hard ceiling"; ADR finalized into `docs/architecture/` with the before/after ledger runs as evidence.

**Rough shape of effort:** Waves 0–1 ≈ 2 weeks; Wave 2 ≈ 2–3 weeks (churn-heavy); Wave 3 ≈ 3–4 weeks (the risky middle); Waves 4–6 ≈ 4+ weeks combined; total a solid quarter of fleet-time. Consistent with the triad's observed pace (Phases 1–5 took ~a month of comparable scope).

---

## 5. How the test-coverage fleet plugs in

General contract: **no extraction PR merges unless the target's pre-wave test pack existed BEFORE the move and passes identically AFTER it.** "Identically" for contract snapshots means byte-equal JSON under `PalaceTests/Contract/__Snapshots__/` (re-record only with `CONTRACT_SNAPSHOT_RECORD=1` + reviewed diff). Coverage is measured per CLAUDE.md: full-scheme runs only (`scripts/xcode-test-optimized.sh` / `verify-pr.sh --quick`), mutation verification via `scripts/palace_mutate.py --file <moved file> --tests <class>` with `--diff-only` on wave branches; kill-rate on moved critical-path files must be ≥ the pre-move baseline (record baseline in the wave brief).

| Target | Exists today | Fleet must build BEFORE its wave | Wave |
|---|---|---|---|
| **AccountsManager** | ~57 unit tests; `AppContainerResetTests`; no contract suite | Characterization pack: registry-crawl lifecycle (start/cancel/drain — deterministic Task-join seams per the de-flake pattern memo, *not* sleeps), slim-vs-full hydration (CP-D1), disk-cache TTL/corruption, auth-doc fetch → `AccountStateStore` transition contract test, currentAccount-switch publication order | 3a |
| **MyBooksDownloadCenter** | 23 tests (thin); Borrow/BookReturn/DownloadStart contract suites | `BackgroundReconciliationContractTests` (INV-4 adopt-don't-double-start, INV-6 transient retry, INV-7 completion handler) against a stubbed URLSession; throttling/disk-budget edge tests; mid-flight-drop (PP-4114) characterization; DRM dispatch contract (spy `FulfillmentHandling` recording call order per format) | 3b |
| **BorrowOperation** | `BorrowOperationContractTests` + `BorrowReducerContractTests` + circuit-breaker units — already the model citizen | Nothing new; suites re-run green post-move (snapshot byte-equal) | 3b |
| **TPPSignInBusinessLogic** | **0 dedicated tests** (unchanged since triad) — the single worst test debt in the repo | Full characterization pack, ≥30 tests: basic/OAuth/SAML/Clever/OIDC happy paths, token-request error branches, credential persistence (mock keychain), DRM-activation skip decisions, sign-out. Then AuthReducer integration parity tests (reducer output == legacy state machine on recorded scenarios). Mutation gate: ≥40% kill minimum, 100% on conditional/return-flip mutants for the flow engines (triad's stated bar) | 4 (blocking prerequisite) |
| **BookDetailViewModel** | 81–125 tests (directly mutate `@Published`) + `BorrowReducerContractTests` | Pin-before-extract for the moving clusters only: metadata-hydration stub-response tests, related-books/series-row tests, open-routing decision table (format → router destination). Existing tests must remain untouched-and-green (the snapshot/apply constraint) | 5 |
| **AudiobookSessionManager** | `AudiobookPositionAdapterContractTests`, `PositionWriterContractTests`; scattered playback tests | Session-state contract test (spy toolkit manager recording bind/play/teardown call order); position-resolution decision table (local vs remote vs none — PP-4542 cases); readiness-gate characterization (F-011: play deferred until gate opens); TOC-normalizer pure-function units. LCP first-open stays sim-verified (simdrive) — no unit seam without DRM | 6 |

Fleet mechanics: each wave brief hands an implementation agent (a) the §3a cluster table row, (b) the required test list above, (c) the CI gate definition. Test-building agents can run **ahead** of extraction waves in parallel (tests against current code are wave-independent) — the sign-in characterization pack in particular should start immediately, since it gates Wave 4 and depends on nothing.

---

## 6. Risks & honest caveats

1. **Money-path exposure is concentrated in Wave 3b and Wave 4.** Borrow/download/DRM-fulfillment and sign-in are where a regression costs users access. Mitigations are structural (contract snapshots byte-equal across the move; mutation kill-rate ratchet; `/rigorous-fix`-grade SoD review on those waves) — but the honest statement is that moving 2,000+ LOC of fulfillment plumbing is never risk-free, and the wave should land early in a release cycle, never near a cut.
2. **CI is the only full build gate for DRM.** There is no local DRM build; `@Sendable`/isolation ripples from package extraction can surface only in CI (documented prior incident: completion-param Sendable ripple). Budget for CI-round-trip iteration on every extraction PR; keep PRs small enough that a red CI bisects trivially. The noDRM target additionally isn't in CI — build-green ≠ launch-green there; sim-launch spot-checks after waves that touch linking.
3. **Package extraction changes access control, not just location.** Everything moved needs `public`/`package` annotations and loses `@testable` visibility from PalaceTests unless tests move too or surfaces widen deliberately. This is real per-wave engineering, and it is also the point — the narrowed surface is the architecture. Watch for the ObjC constraint specifically: `@objc` types (TPPSignInBusinessLogic facade, legacy OPDS parsing) cannot move into Swift-only packages; shells stay behind.
4. **Swift 6 strict concurrency compounds the churn.** New packages inherit the v6-mode convention (per existing manifests); code that was tolerated in the app target's mode may need real isolation fixes when moved. Treat each move as move+annotate, and use the known traps list (off-main @MainActor closures, `#filePath`) from the Swift-6 test-infra memo.
5. **Ledger measurement caveats.** Edge inference is name-based; one confirmed invented edge (TriageBotUI↔Palace) means other low-confidence edges may exist, and cycle-count gates must run on import-verified edges or carry confidence weighting (Wave 0 item). Also "hotspots" = fan-in×churn, not complexity — high fan-in on Layer-0 packages is *desired*; the gate must not punish it.
6. **The systemic test-pollution debt intersects Wave 3a.** The AccountsManager background-crawl is the documented root of much of the flake pollution; the decomposition is the durable fix but also destabilizes the fragile drain/reset choreography in `AppContainer._resetForTesting` mid-wave. The wave brief must include updating the reset seams in the same PRs, and full-suite (not subset) verification per CLAUDE.md is non-negotiable there.
7. **Two cycles end gate-enforced, not compiler-enforced, in the medium term:** Book↔CatalogUI's view-navigation back-edge (both sides remain app-target Presentation) and anything else Presentation-internal. Compiler enforcement for those arrives only if/when the UI itself is packaged — out of scope here; the ledger layer gate is the enforcement in the interim. Similarly `PalaceAudiobookSession` is conditional on the toolkit (§3a-1); its decomposition happens regardless, its compile-enforcement may lag.
8. **Timeline realism.** This is a quarter-scale campaign in fleet-time, longer in calendar time if release cycles interleave (release-freeze windows exclude Waves 3b/4 landings). The ratchet (Wave 0) is what makes a long campaign survivable: even if later waves slip, the problem stops compounding — the 19-day +1,400-LOC accretion trend is the strongest argument that Wave 0 lands this week regardless of everything else.
