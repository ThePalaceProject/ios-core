---
name: palacenetwork-swift6-modernization
created: 2026-06-29
author: claude
---

# palacenetwork-swift6-modernization

PM-assigned modernization fan-out (playbook proven by #1129 PalaceLogging). 3-in-1
consolidation on the PalaceNetwork package: (1) Package.swift manifest bug; (2)
Swift 6 strict-concurrency warnings; (3) fold in #3 (the test real-network escape,
same file family). Design-first; commit-only on `modernize/palacenetwork-swift6`;
PM PRs + SoD.

## Claims

- **Manifest:** drop the phantom `.testTarget(name: "PalaceNetworkTests")` from
  `Package.swift` — there is no in-package `Tests/` dir (PalaceNetwork's tests
  live in the app's `PalaceTests` target), so the declaration broke standalone
  `swift build`/`swift test`. After: `swift build` resolves + builds the package
  on its own (verified: "Build complete!").
- **Concurrency:** the ONLY PalaceNetwork strict-concurrency warnings (verified
  via `swift build -Xswiftc -strict-concurrency=complete`) are 2
  `#SendableClosureCaptures` in `Reachability.startMonitoring`'s NWPathMonitor
  `@Sendable pathUpdateHandler` capturing `self`. Fixed by conforming
  `Reachability` to `@unchecked Sendable` (NOT `nonisolated(unsafe)`), justified:
  `_isConnected` is stateLock-guarded, `connectivitySubject.send` is main-only,
  NWPathMonitor is internally thread-safe. After: 0 PalaceNetwork warnings.
- **#3 (folded in):** close the TPPNetworkExecutor test real-network escape so
  `AccountsManager.fallbackDirectRefresh` can't reach `registry.palaceproject.io`
  in tests. DONE via a non-`#if DEBUG` AppContainer seam (PM's option B / hard
  no-DEBUG constraint): `AppContainer.testExecutorProtocolClasses` (empty in
  production → zero change) + `makeNetworkExecutor()` builds the shared executor
  through the EXISTING `init(sessionConfiguration:)` with those classes prepended;
  `PalaceTestSetup` installs `[NoNetworkURLProtocol]` and calls a non-DEBUG
  `AppContainer._rebuildCachedForTestProtocols()` (the launch-built graph predates
  the test bundle, and the per-test `_resetForTesting` rebuild is `#if DEBUG`,
  which is COMPILED OUT in the non-DEBUG config `harness test` uses — measured).
  Block-test `ExecutorNetworkHermeticityTests` proves a shared-executor GET to a
  non-stub host is blocked (fast-fail, no real request) — green.

- **Language mode:** bump `swift-tools-version` to 6.0 so the PalaceNetwork
  source target builds in Swift 6 language mode by default (playbook: source →
  .v6). No in-package test target exists, so no `.v5` test override is needed.
  Verified: `swift build` (v6 mode) completes with 0 errors / 0 warnings — the
  `@unchecked Sendable` fix covers everything full-v6 surfaces.

## Anti-claims

- does NOT use `nonisolated(unsafe)` anywhere (playbook rule).
- does NOT change any public symbol of PalaceNetwork (whole-repo grep clean) —
  `@unchecked Sendable` conformance is additive (no consumer/test-double ripple).

## #3 design question — RESOLVED (2026-06-30)

The earlier-flagged gap ("the seam doesn't cover `AppContainer.production()
.networkExecutor`, the path AccountsManager.fallbackDirectRefresh actually
leaks through") is CLOSED by the shipped mechanism: `makeNetworkExecutor()` is
the builder used by `_buildCachedAppContainer()`, which builds the very `_cached`
graph `production()` returns. `_rebuildCachedForTestProtocols()` re-runs that
builder AFTER `PalaceTestSetup` installs `[NoNetworkURLProtocol]`, so the
production/shared executor itself picks up the stub — not just an
`init(sessionConfiguration:)`-injected one. The block-test reads
`AppContainer.production().networkExecutor` (the real shared executor) and now
asserts POSITIVE interception (NoNetworkURLProtocol.interceptionCount), so it
fails exactly when the seam regresses. SoD architect + qa + blast-radius all
APPROVE-WITH-NITS (2026-06-30); no `#if DEBUG` on a production path (BR-2 honored).

## Residual escape sites (87 → 6) — enumerated follow-up

The seam only rebuilds the executor built by `_buildCachedAppContainer`. Other
executors / raw `URLSession(configuration:)` are NOT routed through it and remain
the documented residual escapes (suite real-network count dropped 87 → 6, not to
0). They are out of scope for #3 (which targets the shared/`fallbackDirectRefresh`
escape) and tracked here for a follow-up hermeticity pass:
- `AccountDetailViewModel.swift:157` — own `TPPNetworkExecutor(credentialsProvider:
  cachingStrategy: .ephemeral)`
- `TPPSignInBusinessLogic.swift:59` — own `TPPNetworkExecutor(...)`
- raw `URLSession(configuration:)` in `TPPBookCoverRegistry`,
  `TPPCirculationAnalytics`, `MyBooksDownloadCenter`, `LicensesService`,
  `NetworkTransport`

## Inherited isolation debt (app-target Swift 6 follow-up)

`AppContainer.testExecutorProtocolClasses` is a mutable `static var` with no
isolation annotation. Safe today — the app target is Swift 5, it is written once
on the main thread at test-bundle principal-class load before any test runs, and
it mirrors the pre-existing un-isolated `_cached` static. When the **app target**
flips to Swift 6 (a later modernization module), this (like `_cached`) will need
explicit isolation (`@MainActor` or documented `nonisolated(unsafe)`). Tracked so
the app-target bump doesn't surface it as a fresh error.

## Files in scope

- Palace/Packages/PalaceNetwork/Package.swift (manifest + tools 6.0)
- Palace/Packages/PalaceNetwork/Sources/PalaceNetwork/Reachability.swift (@unchecked Sendable)
- Palace/AppInfrastructure/AppContainer.swift (#3 seam: testExecutorProtocolClasses + makeNetworkExecutor + _rebuildCachedForTestProtocols)
- PalaceTests/PalaceTestSetup.swift (#3 wiring: install stub + rebuild cached graph)
- PalaceTests/NoNetworkURLProtocol.swift (#3: interception counter for positive proof)
- PalaceTests/Network/ExecutorNetworkHermeticityTests.swift (#3 block-test)
