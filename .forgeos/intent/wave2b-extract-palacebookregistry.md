---
name: wave2b-extract-palacebookregistry
created: 2026-07-27
author: claude-opus-4-8
type: refactor
tracking: God-class decomposition Wave 2b (keystone-second-half) — extract the TPPBookRegistry engine cluster into the PalaceBookRegistry SPM package and invert its Accounts dependency behind a value-only protocol, provably behavior-neutral against the Wave-2b contract snapshots. Critical path (borrow/sync/download/persistence/auth).
related_prs: []
---

# Intent: extract PalaceBookRegistry + invert the Accounts dependency

## Claims
- Moves the registry engine cluster (`TPPBookRegistry` facade + `TPPBookRegistryProvider`,
  `BookRegistrySync`, `BookRegistryStore`, `BookmarkManager`, `RegistryFileRecovery`)
  from `Palace/Book/Models/` into a new local SPM package
  `Palace/Packages/PalaceBookRegistry/` (deps: PalaceBookModel, PalaceCatalog,
  PalaceLogging; `.swiftLanguageMode(.v6)`, iOS 17).
- Inverts the Book→Accounts edge behind a value-only `AccountScopeProviding`
  protocol (4 members: `currentAccountID`, `accountDidChangePublisher`,
  `hasCredentials(forAccount:)`, `loansURL(forAccount:)`), adapted app-side by
  `AccountsManagerAccountScopeAdapter`. Preserves the PP-4129 synchronous
  account-capture-at-dispatch discipline.
- Injects the engine's external collaborators via a `RegistryExternalDependencies`
  bundle (download service via the new `RegistryDownloadServicing` protocol,
  loans-feed fetcher via `OPDSFeedFetching` relocated to PalaceCatalog, sideload
  set, registry-directory path rule, availability-change hook) — all resolved
  lazily by the composition root with the SAME deferred `AppContainer.production()`
  timing the former inline closures had.
- Relocates the `#if LCP` license-vs-content probe (`checkIfBookFileExists` +
  the `.lcpa`-missing check) into `MyBooksDownloadCenter`'s app-side
  `RegistryDownloadServicing` conformance (`contentFileSatisfied` /
  `lcpContentFileMissing`) because SPM targets don't inherit the app's `LCP`
  define; noDRM returns the non-LCP behavior. Byte-identical.
- Relocates the four registry `Notification.Name`s (TPPSyncBegan/Ended/Failed,
  TPPBookRegistryDidChange) into the package with identical string values; the
  store's processing notification kept via a distinct-symbol/same-string
  package-internal name.
- Wires it through AppContainer (a `(accountsManager:imageLoader:)` convenience
  init + `RegistryExternalDependencies.production()`), moves the
  `TPPBookRegistrySyncing` conformance to an app-side extension, de-objcs the
  cluster surface, and links the package product into Palace + Palace-noDRM +
  PalaceTests. ~112 app/test files gain `import PalaceBookRegistry`; ~11
  white-box suites gain `@testable import PalaceBookRegistry`.

## Anti-claims
- Changes NO registry behavior. Publisher `.receive(on: RunLoop.main)` timing, the
  `BoolWithDelay` 5s sync-notification debounce, the PP-4129 account capture, the
  INV-1 rebuild-window save refusal, the `#if LCP` probe equivalence across all
  three build flavors, and the `_resetForTesting`/background-crawl choreography all
  move byte-identically. The behavior-neutral proof is zero diffs under
  `PalaceTests/Contract/__Snapshots__/` (CONTRACT_SNAPSHOT_RECORD never set).
- The package holds ZERO code edge to accounts/downloads/AppContainer/
  NotificationService/TPPUserAccount/LCPAudiobooks (comment-stripped purity grep = 0).
- Does NOT drop to `.v5` language mode; does NOT modernize delivery while moving.

## Files in scope
- New package: `Palace/Packages/PalaceBookRegistry/**`
- Relocated seam: `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/OPDSFeedFetching.swift`
- New app-side: `AccountsManagerAccountScopeAdapter.swift`,
  `MyBooksDownloadCenter+RegistryDownloadServicing.swift`,
  `TPPBookRegistry+AppConformances.swift`, `TPPBookRegistry+ProductionInit.swift`
- New tests: `AccountScopeAdapterTests.swift`,
  `RegistryDownloadServicingSeamTests.swift`, `BookRegistryEngineTestInits.swift`
- Wiring: `AppContainer.swift`, `NSNotification+TPP.swift`,
  `TPPSignInBusinessLogic.swift`, both pbxproj targets, + ~112 `import` additions.

## Deferred
- The `#if LCP`-define-gated license branch of `contentFileSatisfied`/
  `lcpContentFileMissing` (the `.lcpl`-only-satisfied path) is exercised only in an
  LCP build with an LCP-audiobook fixture; the isolated LCP-branch unit test is
  deferred to a fast-follow. It is de-risked here by (a) byte-identical relocation
  (diff-verified), (b) noDRM build+launch verification, and (c) the non-LCP branch
  covered by `RegistryDownloadServicingSeamTests`.
- Mutation kill-rate re-run vs `docs/architecture/wave2b-mutation-baseline.md`
  (heka `mutation` gate, merge-enforced by CI).
- `TPPBookRegistryMock` NSObject drop; the `syncAsync`/`sideloadedIDs`
  `AppContainer.production()` locator-arg kills.
