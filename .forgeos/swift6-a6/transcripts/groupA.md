# Swift 6 `targeted` sweep — Phase A.6, GROUP A transcript

Isolation-only fixes. No behavior change. Edited ONLY GROUP A files. No production
(`Palace/...`) file touched. 16 warnings across 13 files fixed.

## PalaceTests/AppInfrastructure/AppContainerTests.swift (2 warnings)
- `56:36` + `94:36` — `main actor-isolated class property 'shared' can not be referenced from a nonisolated context` (`userAccountPublisher: .shared`, resolving `UserAccountPublisher.shared`).
  - Fix (pattern 3): marked the two enclosing test methods `@MainActor`:
    `testInit_withMockBookRegistry_exposesTheMockNotTheProductionRegistry`,
    `testInit_twoContainersWithDifferentRegistries_remainIndependent`. Narrowest scope; both are plain XCTest methods dispatching on main.

## PalaceTests/Audiobook/AudiobookDataManagerSyncTests.swift (1)
- `24:7` — `class 'MockNetworkExecutorForSync' must restate inherited '@unchecked Sendable' conformance`.
  - Fix (pattern 1): `TPPNetworkExecutor` → `TPPNetworkExecutor, @unchecked Sendable`.

## PalaceTests/Audiobook/Vendors/LocalFileAdapterTests.swift (2)
- `20:11` — `add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'Palace'`.
  - Fix (pattern 6): `@testable import Palace` → `@preconcurrency @testable import Palace`.
- `95:28` — `capture of 'toReturn' with non-Sendable type 'MyBooksSimplifiedBearerToken?' in a '@Sendable' closure` (inside `DispatchQueue.main.async` in `StubTokenRefresher.refreshToken`).
  - Fix (pattern 5): introduced a documented private `TokenBox: @unchecked Sendable` carrier; boxed `stubbedToken` before the closure and passed `box.value` to `completion`.

## PalaceTests/Bookmarks/TPPAnnotationsTests.swift (1)
- `1124:21` — `class 'RecordingExecutorMock' must restate inherited '@unchecked Sendable' conformance`.
  - Fix (pattern 1): `TPPNetworkExecutor` → `TPPNetworkExecutor, @unchecked Sendable`.

## PalaceTests/Mocks/CatalogRepositoryMock.swift (1) — DEVIATION FROM LITERAL PATTERN 2
- `17:40` — `conformance of 'CatalogRepositoryTestMock' to protocol 'CatalogRepositoryProtocol' crosses into main actor-isolated code`.
  - Investigation: `CatalogRepositoryProtocol` is declared `public protocol CatalogRepositoryProtocol: Sendable` (nonisolated) in `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/CatalogRepository.swift:8`. The mock was **already** `@MainActor`. A `@MainActor` witness of a `Sendable` protocol is the CAUSE of this crossing warning, not the cure — so the task's literal pattern-2 "add `@MainActor`" was already present and cannot resolve it.
  - Fix (isolation-only, behavior-preserving): kept `@MainActor` (consumers are `@MainActor` view models) and added `@preconcurrency` to the conformance: `@preconcurrency CatalogRepositoryProtocol`. This defers the Sendable isolation check without changing the mock's threading. Documented inline.
  - Alternative considered: drop `@MainActor` + add `@unchecked Sendable` (matches production `CatalogRepository: CatalogRepositoryProtocol, @unchecked Sendable`). Rejected as higher-risk (changes where the mock may be touched); `@preconcurrency` is the minimal diff. Flagged for integration review.

## PalaceTests/Mocks/MockFeatureFlagProvider.swift (1)
- `14:9` — `stored property 'isOPDS2Enabled' of 'Sendable'-conforming class 'MockFeatureFlagProvider' is mutable`.
  - Fix (pattern 4): added `, @unchecked Sendable` to the class (overriding the inherited `FeatureFlagProvider: Sendable` requirement) + doc comment noting serial test-flow confinement. Mutability retained.

## PalaceTests/Mocks/MockPDFDocumentMetadata.swift (1)
- `12:7` — `class 'MockPDFDocumentMetadata' must restate inherited '@unchecked Sendable' conformance`.
  - Fix (pattern 1): `TPPPDFDocumentMetadata` → `TPPPDFDocumentMetadata, @unchecked Sendable`.

## PalaceTests/Mocks/MockReachability.swift (1)
- `15:13` — `class 'MockReachability' must restate inherited '@unchecked Sendable' conformance`.
  - Fix (pattern 1): `Reachability` → `Reachability, @unchecked Sendable`.

## PalaceTests/Mocks/MockVisualNavigator.swift (2) — DEVIATION FROM LITERAL PATTERN 2
- `19:13` + `19:44` — conformance of `MockVisualNavigator` to `Navigator` / `VisualNavigator` crosses into main actor-isolated code.
  - Investigation: in Readium (swift-toolkit) `public protocol Navigator: AnyObject` and `public protocol VisualNavigator: Navigator, InputObservable` are BOTH nonisolated (not `@MainActor`). The mock was **already** `@MainActor`, which is the cause of the crossing warning. The task note "one `@MainActor` clears both" does not hold — `@MainActor` was present and did not clear it.
  - Fix (isolation-only, behavior-preserving): kept `@MainActor` (a visual navigator is main-thread UI) and added `@preconcurrency` to the conformance: `NSObject, @preconcurrency VisualNavigator`. One `@preconcurrency` on the direct `VisualNavigator` conformance covers the inherited `Navigator` requirement too. Documented inline.

## PalaceTests/Mocks/NetworkClientMock.swift (1)
- `24:9` — `stored property 'stubbedResponses' of 'Sendable'-conforming class 'NetworkClientMock' is mutable`.
  - Fix (pattern 4): added `, @unchecked Sendable` (overriding inherited `NetworkClient: Sendable`) + doc noting mutable stubs are `lock`-guarded and configured on the serial test flow. Mutability retained.

## PalaceTests/Mocks/SpyAudiobookNetworkExecutor.swift (1)
- `24:13` — `class 'SpyAudiobookNetworkExecutor' must restate inherited '@unchecked Sendable' conformance`.
  - Fix (pattern 1): `TPPNetworkExecutor` → `TPPNetworkExecutor, @unchecked Sendable`.

## PalaceTests/Mocks/TPPUserAccountMock.swift (1)
- `12:7` — `class 'TPPUserAccountMock' must restate inherited '@unchecked Sendable' conformance`.
  - Fix (pattern 1): `TPPUserAccount` → `TPPUserAccount, @unchecked Sendable`.

## PalaceTests/Support/TestAppContainerFactory.swift (1)
- `150:28` — `main actor-isolated class property 'shared' can not be referenced from a nonisolated context` (`userAccountPublisher: .shared`).
  - Context: `makeTestAppContainer(...)` is deliberately NOT `@MainActor` (documented isolation note so nonisolated `XCTestCase` methods can call it); marking it `@MainActor` would break that contract. It already uses `MainActor.assumeIsolated { ... }` for the `AuthCoordinator` step.
  - Fix (isolation-only): mirrored the production builder at `AppContainer.swift:478` — hoisted `let userAccountPublisher = MainActor.assumeIsolated { UserAccountPublisher.shared }` and passed it into `AppContainer(...)`. Documented inline.

## Summary
- Files modified (13, all GROUP A): AppContainerTests.swift, AudiobookDataManagerSyncTests.swift, LocalFileAdapterTests.swift, TPPAnnotationsTests.swift, CatalogRepositoryMock.swift, MockFeatureFlagProvider.swift, MockPDFDocumentMetadata.swift, MockReachability.swift, MockVisualNavigator.swift, NetworkClientMock.swift, SpyAudiobookNetworkExecutor.swift, TPPUserAccountMock.swift, TestAppContainerFactory.swift.
- Warnings fixed: 16.
- Production files touched: NONE.
- Deviations flagged for integration review: CatalogRepositoryMock.swift + MockVisualNavigator.swift — used `@preconcurrency` on the conformance instead of adding `@MainActor` (the classes were already `@MainActor`, and their protocols are nonisolated, so `@MainActor` was the cause, not the cure). No build run (forbidden by task); reasoning grounded in the protocol declarations cited above.
