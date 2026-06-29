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
- **#3 (folding in):** close the TPPNetworkExecutor test real-network escape so
  `AccountsManager.fallbackDirectRefresh` can't reach `registry.palaceproject.io`
  in tests. MECHANISM UNDER DISCUSSION with PM (see Anti-claims) — not yet coded.

## Anti-claims

- does NOT bump `swift-tools-version` (the #1129 model kept 5.9; the work is
  source-level concurrency-cleanliness, not a manifest language-mode flip).
- does NOT use `nonisolated(unsafe)` anywhere (playbook rule).
- does NOT change any public symbol of PalaceNetwork (whole-repo grep clean) —
  `@unchecked Sendable` conformance is additive (no consumer/test-double ripple).
- #3 OPEN DESIGN QUESTION for PM: the chosen mechanism (3a "existing
  init(sessionConfiguration:) seam") does NOT cover the path that actually leaks —
  AccountsManager uses `AppContainer.production().networkExecutor` (the DEFAULT
  init, no injected config), not an init(sessionConfiguration:) call. Options:
  (3b) a DEBUG injection point in PalaceNetwork (e.g. `TPPCaching` exposes a
  test-settable `[AnyClass]` of extra protocolClasses that `makeURLSessionConfiguration`
  prepends; PalaceTests fills it with `NoNetworkURLProtocol`) — PM earlier
  declined "new DEBUG prod surface"; OR a test seam to swap AppContainer's
  executor for one built via init(sessionConfiguration:). Resolve before coding #3.

## Files in scope

- Palace/Packages/PalaceNetwork/Package.swift (manifest)
- Palace/Packages/PalaceNetwork/Sources/PalaceNetwork/Reachability.swift (@unchecked Sendable)
- Palace/Packages/PalaceNetwork/Sources/PalaceNetwork/TPPCaching.swift (#3 — pending mechanism)
- PalaceTests/* bootstrap + a block-test (#3 — pending mechanism)
