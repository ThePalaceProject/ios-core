# Test Seams Refactor Plan

**Document Version:** 1.0
**Last Updated:** 2026-01-29

---

## 1. Executive Summary

This document outlines a systematic plan to introduce testability seams into the Palace iOS codebase without destabilizing existing behavior. The goal is to enable dependency injection for the 30+ singletons currently blocking comprehensive test coverage.

### Principles

1. **Incremental Changes:** Each refactor is small and independently mergeable
2. **Backward Compatible:** Existing code continues to work unchanged
3. **No Behavior Changes:** Only structural changes to enable testing
4. **Protocol-First:** Extract protocols before changing implementations

---

## 2. Singleton Inventory

### 2.1 Critical Singletons (P0 - Block Core Testing)

| Singleton | File | Usage Count | Impact |
|-----------|------|-------------|--------|
| `AccountsManager.shared` | `AccountsManager.swift:44` | High | Blocks auth tests |
| `TPPNetworkExecutor.shared` | `TPPNetworkExecutor.swift:59` | Very High | Blocks all network tests |
| `TPPBookRegistry.shared` | `TPPBookRegistry.swift` | Very High | Blocks book state tests |
| `TPPUserAccount.sharedAccount()` | `TPPUserAccount.swift` | High | Blocks credential tests |
| `MyBooksDownloadCenter.shared` | `MyBooksDownloadCenter.swift` | Medium | Blocks download tests |

### 2.2 High-Impact Singletons (P1 - Block Feature Testing)

| Singleton | File | Usage Count | Impact |
|-----------|------|-------------|--------|
| `TPPSettings.shared` | `TPPSettings.swift` | High | Settings pollution |
| `AudiobookSessionManager.shared` | `AudiobookSessionManager.swift` | Medium | Blocks audiobook tests |
| `NavigationCoordinatorHub.shared` | `NavigationCoordinatorHub.swift` | Medium | Blocks navigation tests |
| `OPDS2FeedCache.shared` | `OPDS2FeedCache.swift` | Medium | Cache state leakage |
| `OPDSFeedService.shared` | `OPDSFeedService.swift` | Medium | Service isolation |

### 2.3 Lower-Impact Singletons (P2 - Nice to Have)

| Singleton | File | Usage Count | Impact |
|-----------|------|-------------|--------|
| `FirebaseManager.shared` | `FirebaseManager.swift` | Low | Analytics isolation |
| `TPPBookCoverRegistry.shared` | `TPPBookCoverRegistry.swift` | Medium | Image cache |
| `Reachability` | `Reachability.swift` | Low | Network status |
| `ImageCache.shared` | `ImageCache.swift` | Medium | Image caching |
| `BookCellModelCache.shared` | `BookCellModelCache.swift` | Medium | View model cache |

---

## 3. Seam Implementation Patterns

### 3.1 Pattern A: Protocol Extraction + Default Parameter

**Best for:** Classes that are already injected in some places

**Steps:**
1. Extract protocol from public interface
2. Make singleton conform to protocol
3. Add protocol parameter with default value

**Example: TPPNetworkExecutor**

```swift
// Step 1: Extract protocol (new file)
// Palace/Network/TPPNetworkExecuting.swift

protocol TPPNetworkExecuting: AnyObject {
    func GET(_ reqURL: URL,
             useTokenIfAvailable: Bool,
             completion: @escaping (NYPLResult<Data>) -> Void)

    func POST(_ request: URLRequest,
              useTokenIfAvailable: Bool,
              completion: ((Data?, URLResponse?, Error?) -> Void)?)

    // ... other methods
}

// Step 2: Conform existing class
// Palace/Network/TPPNetworkExecutor.swift

extension TPPNetworkExecutor: TPPNetworkExecuting { }

// Step 3: Update consumers with default parameter
// Palace/Accounts/Library/AccountsManager.swift

final class AccountsManager: NSObject, TPPLibraryAccountsProvider {
    private let networkExecutor: TPPNetworkExecuting

    // New init with injection
    init(networkExecutor: TPPNetworkExecuting = TPPNetworkExecutor.shared) {
        self.networkExecutor = networkExecutor
        // ... rest of init
    }

    // Keep existing shared singleton
    static let shared = AccountsManager()
}
```

**Risk Level:** Low - No behavior change, additive only

---

### 3.2 Pattern B: Provider Protocol

**Best for:** Singletons accessed directly in many places

**Steps:**
1. Create provider protocol
2. Create default implementation that returns singleton
3. Inject provider instead of singleton directly

**Example: TPPSettings**

```swift
// Step 1: Create provider protocol
// Palace/Settings/TPPSettingsProviding.swift

protocol TPPSettingsProviding: AnyObject {
    var useBetaLibraries: Bool { get set }
    var accountMainFeedURL: URL? { get set }
    var customMainFeedURL: URL? { get }
    var userHasAcceptedEULA: Bool { get set }
    // ... other properties
}

// Step 2: Conform existing class
extension TPPSettings: TPPSettingsProviding { }

// Step 3: Create mock for tests
// PalaceTests/Mocks/TPPSettingsMock.swift

final class TPPSettingsMock: TPPSettingsProviding {
    var useBetaLibraries: Bool = false
    var accountMainFeedURL: URL?
    var customMainFeedURL: URL?
    var userHasAcceptedEULA: Bool = false
    // ... mock implementations
}
```

**Risk Level:** Low - Protocol is read from existing class

---

### 3.3 Pattern C: Factory/Container

**Best for:** Complex object graphs with multiple dependencies

**Steps:**
1. Create dependency container protocol
2. Create production container
3. Create test container

**Example: Test Dependency Container**

```swift
// PalaceTests/TestSupport/TestDependencyContainer.swift

protocol DependencyProviding {
    var networkExecutor: TPPNetworkExecuting { get }
    var accountsManager: TPPLibraryAccountsProvider { get }
    var bookRegistry: TPPBookRegistryProviding { get }
    var settings: TPPSettingsProviding { get }
}

// Production container
final class ProductionDependencyContainer: DependencyProviding {
    var networkExecutor: TPPNetworkExecuting { TPPNetworkExecutor.shared }
    var accountsManager: TPPLibraryAccountsProvider { AccountsManager.shared }
    var bookRegistry: TPPBookRegistryProviding { TPPBookRegistry.shared }
    var settings: TPPSettingsProviding { TPPSettings.shared }
}

// Test container
final class TestDependencyContainer: DependencyProviding {
    var networkExecutor: TPPNetworkExecuting = NYPLNetworkExecutorMock()
    var accountsManager: TPPLibraryAccountsProvider = AccountsManagerMock()
    var bookRegistry: TPPBookRegistryProviding = TPPBookRegistryMock()
    var settings: TPPSettingsProviding = TPPSettingsMock()

    static func reset() {
        // Reset all mocks to default state
    }
}
```

**Risk Level:** Medium - Requires careful rollout

---

### 3.4 Pattern D: Clock Abstraction

**Best for:** Time-dependent code

**Steps:**
1. Create clock protocol
2. Replace `Date()` calls with clock
3. Inject clock with default to system clock

```swift
// Palace/Utilities/Clock.swift

protocol ClockProviding {
    var now: Date { get }
}

struct SystemClock: ClockProviding {
    var now: Date { Date() }
}

// Usage in CatalogCacheMetadata
struct CatalogCacheMetadata: Codable {
    let timestamp: Date
    let hash: String

    // Injected clock for testing
    func isStale(clock: ClockProviding = SystemClock()) -> Bool {
        clock.now.timeIntervalSince(timestamp) > Self.staleTTL
    }
}

// Test
final class MockClock: ClockProviding {
    var now: Date = Date()

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}
```

---

### 3.5 Pattern E: URLProtocol Registration

**Already Implemented:** `HTTPStubURLProtocol`

**Usage:**

```swift
// Create session configuration that uses stub protocol
let config = URLSessionConfiguration.ephemeral
config.protocolClasses = [HTTPStubURLProtocol.self]

// Inject into TPPNetworkExecutor
let executor = TPPNetworkExecutor(
    credentialsProvider: nil,
    cachingStrategy: .fallback,
    sessionConfiguration: config  // Uses test-friendly init
)
```

---

## 4. Phased Implementation Plan

### Phase 1: P0 Singletons (Weeks 1-2)

#### 4.1.1 TPPNetworkExecutor

**Files to Modify:**

| File | Change |
|------|--------|
| `Palace/Network/TPPNetworkExecuting.swift` | Create protocol (new) |
| `Palace/Network/TPPNetworkExecutor.swift` | Add protocol conformance |
| `PalaceTests/Mocks/NYPLNetworkExecutorMock.swift` | Update to conform |

**Protocol Definition:**

```swift
@objc protocol TPPNetworkExecuting: AnyObject {
    func GET(_ reqURL: URL,
             useTokenIfAvailable: Bool,
             completion: @escaping (NYPLResult<Data>) -> Void)

    @discardableResult
    func GET(_ reqURL: URL,
             cachePolicy: NSURLRequest.CachePolicy,
             useTokenIfAvailable: Bool,
             completion: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask?

    @discardableResult
    func POST(_ request: URLRequest,
              useTokenIfAvailable: Bool,
              completion: ((Data?, URLResponse?, Error?) -> Void)?) -> URLSessionDataTask?

    @discardableResult
    func PUT(request: URLRequest,
             useTokenIfAvailable: Bool,
             completion: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask?

    @discardableResult
    func DELETE(_ request: URLRequest,
                useTokenIfAvailable: Bool,
                completion: ((Data?, URLResponse?, Error?) -> Void)?) -> URLSessionDataTask?

    func clearCache()
}
```

**Risk:** Low
**Effort:** 4 hours
**PR Size:** ~200 lines

---

#### 4.1.2 AccountsManager

**Files to Modify:**

| File | Change |
|------|--------|
| `Palace/Accounts/Library/AccountsManager.swift` | Add init with DI |
| `PalaceTests/Mocks/AccountsManagerMock.swift` | Create mock |

**Changes:**

```swift
@objcMembers final class AccountsManager: NSObject, TPPLibraryAccountsProvider {

    static let shared = AccountsManager()

    private let networkExecutor: TPPNetworkExecuting
    private let settings: TPPSettingsProviding

    // New testable init
    init(networkExecutor: TPPNetworkExecuting = TPPNetworkExecutor.shared,
         settings: TPPSettingsProviding = TPPSettings.shared) {
        self.networkExecutor = networkExecutor
        self.settings = settings
        // ... existing init code using injected deps
    }

    private override convenience init() {
        self.init(networkExecutor: TPPNetworkExecutor.shared,
                  settings: TPPSettings.shared)
    }
}
```

**Risk:** Medium (touches core auth flow)
**Effort:** 6 hours
**PR Size:** ~300 lines

---

#### 4.1.3 TPPBookRegistry

**Files to Modify:**

| File | Change |
|------|--------|
| `Palace/Book/Models/TPPBookRegistryProviding.swift` | Create protocol (new) |
| `Palace/Book/Models/TPPBookRegistry.swift` | Add protocol conformance |
| `PalaceTests/Mocks/TPPBookRegistryMock.swift` | Update |

**Protocol Definition:**

```swift
protocol TPPBookRegistryProviding: AnyObject {
    var allBooks: [TPPBook] { get }
    var allBookIdentifiers: [String] { get }

    func book(forIdentifier identifier: String) -> TPPBook?
    func add(_ book: TPPBook)
    func remove(_ book: TPPBook)
    func updateState(_ state: TPPBookState, for book: TPPBook)

    var registryPublisher: AnyPublisher<[TPPBook], Never> { get }
    var bookStatePublisher: AnyPublisher<(String, TPPBookState), Never> { get }
}
```

**Risk:** Medium (central state management)
**Effort:** 8 hours
**PR Size:** ~400 lines

---

#### 4.1.4 TPPUserAccount

**Files to Modify:**

| File | Change |
|------|--------|
| `Palace/Accounts/User/TPPUserAccountProviding.swift` | Create protocol (new) |
| `Palace/Accounts/User/TPPUserAccount.swift` | Add protocol conformance |
| `PalaceTests/Mocks/TPPUserAccountMock.swift` | Update |

**Protocol Definition:**

```swift
@objc protocol TPPUserAccountProviding: NSObjectProtocol {
    var barcode: String? { get }
    var PIN: String? { get }
    var authToken: String? { get }
    var authTokenNearExpiry: Bool { get }
    var authDefinition: AccountDetails.Authentication? { get }

    func hasCredentials() -> Bool
    func setAuthToken(_ token: String,
                      barcode: String?,
                      pin: String?,
                      expirationDate: Date?)
    func removeAll()
    func markCredentialsStale()
    func markLoggedIn()
}
```

**Risk:** High (keychain access, auth state)
**Effort:** 10 hours
**PR Size:** ~500 lines

---

#### 4.1.5 MyBooksDownloadCenter

**Files to Modify:**

| File | Change |
|------|--------|
| `Palace/MyBooks/MyBooksDownloadCenter.swift` | Add init with DI |

**Changes:**

```swift
@objcMembers final class MyBooksDownloadCenter: NSObject {

    static let shared = MyBooksDownloadCenter()

    private let userAccount: TPPUserAccountProviding
    private let reauthenticator: TPPReauthenticating
    private let bookRegistry: TPPBookRegistryProviding

    init(userAccount: TPPUserAccountProviding = TPPUserAccount.sharedAccount(),
         reauthenticator: TPPReauthenticating = TPPReauthenticator(),
         bookRegistry: TPPBookRegistryProviding = TPPBookRegistry.shared) {
        self.userAccount = userAccount
        self.reauthenticator = reauthenticator
        self.bookRegistry = bookRegistry
        super.init()
    }
}
```

**Risk:** Medium
**Effort:** 6 hours
**PR Size:** ~250 lines

---

### Phase 2: P1 Singletons (Weeks 3-4)

#### 4.2.1 TPPSettings

**Protocol:**

```swift
protocol TPPSettingsProviding: AnyObject {
    var useBetaLibraries: Bool { get set }
    var accountMainFeedURL: URL? { get set }
    var customMainFeedURL: URL? { get }
    var userPresentedAgeCheck: Bool { get set }
    var userHasAcceptedEULA: Bool { get set }
    var enterLCPPassphraseManually: Bool { get set }
    var showDeveloperSettings: Bool { get }
}
```

**Risk:** Low
**Effort:** 4 hours

---

#### 4.2.2 AudiobookSessionManager

**Protocol:**

```swift
@MainActor
protocol AudiobookSessionProviding: AnyObject {
    var playbackState: AudiobookPlaybackState { get }
    var currentAudiobook: TPPBook? { get }

    func setActiveAudiobook(_ book: TPPBook, player: AudiobookPlayer)
    func clearSession()

    var playbackStatePublisher: AnyPublisher<AudiobookPlaybackState, Never> { get }
}
```

**Risk:** Medium (main actor isolation)
**Effort:** 6 hours

---

#### 4.2.3 NavigationCoordinatorHub

Already has weak reference pattern. Add protocol:

```swift
@MainActor
protocol NavigationCoordinatorProviding: AnyObject {
    var coordinator: NavigationCoordinator? { get }
}
```

**Risk:** Low
**Effort:** 2 hours

---

#### 4.2.4 OPDS Feed Services

**Protocols:**

```swift
protocol OPDSFeedCaching: AnyObject {
    func feed(for url: URL) -> CatalogFeed?
    func cache(_ feed: CatalogFeed, for url: URL)
    func invalidate(for url: URL)
    func clear()
}

protocol OPDSFeedServing: AnyObject {
    func fetchFeed(at url: URL) async throws -> CatalogFeed?
}
```

**Risk:** Low
**Effort:** 4 hours each

---

### Phase 3: Supporting Abstractions (Weeks 5-6)

#### 4.3.1 Clock Abstraction

```swift
// Palace/Utilities/Clock.swift

protocol ClockProviding {
    var now: Date { get }
}

struct SystemClock: ClockProviding {
    var now: Date { Date() }
}

// PalaceTests/TestSupport/MockClock.swift

final class MockClock: ClockProviding {
    var now: Date

    init(now: Date = Date()) {
        self.now = now
    }

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }

    func setTime(_ date: Date) {
        now = date
    }
}
```

**Usage Sites to Update:**
- `CatalogCacheMetadata.isStale`
- `CatalogCacheMetadata.isExpired`
- Token expiry checks
- Cache TTL calculations

**Risk:** Low
**Effort:** 4 hours

---

#### 4.3.2 FileManager Abstraction

```swift
protocol FileManaging {
    func fileExists(atPath path: String) -> Bool
    func contents(atPath path: String) -> Data?
    func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey : Any]?) -> Bool
    func removeItem(atPath path: String) throws
    func url(for directory: FileManager.SearchPathDirectory,
             in domain: FileManager.SearchPathDomainMask,
             appropriateFor url: URL?,
             create shouldCreate: Bool) throws -> URL
}

extension FileManager: FileManaging { }

// Mock
final class FileManagerMock: FileManaging {
    var files: [String: Data] = [:]
    var directories: Set<String> = []

    // ... mock implementations
}
```

**Usage Sites:**
- `TPPBookRegistry` persistence
- `AccountsManager` cache
- Download management

**Risk:** Medium
**Effort:** 8 hours

---

#### 4.3.3 Keychain Abstraction

```swift
protocol KeychainProviding {
    func set(_ data: Data, forKey key: String, accessibility: CFString) throws
    func get(forKey key: String) throws -> Data?
    func delete(forKey key: String) throws
    func deleteAll() throws
}

// Fake for tests
final class KeychainFake: KeychainProviding {
    private var storage: [String: Data] = [:]

    func set(_ data: Data, forKey key: String, accessibility: CFString) throws {
        storage[key] = data
    }

    func get(forKey key: String) throws -> Data? {
        return storage[key]
    }

    func delete(forKey key: String) throws {
        storage[key] = nil
    }

    func deleteAll() throws {
        storage.removeAll()
    }
}
```

**Risk:** High (security-sensitive)
**Effort:** 10 hours

---

## 5. Migration Checklist

### Per-Singleton Checklist

- [ ] Create protocol file
- [ ] Add protocol conformance to existing class
- [ ] Add testable init with default parameters
- [ ] Create/update mock implementation
- [ ] Add unit tests for mock
- [ ] Update one consumer as proof-of-concept
- [ ] Document in Test_Patterns.md
- [ ] Code review
- [ ] Merge

### Verification Steps

1. **No Behavior Change:** All existing tests pass
2. **ObjC Compatibility:** `@objc` protocols where needed
3. **Thread Safety:** Protocols maintain actor isolation
4. **Memory Management:** No retain cycles in injected dependencies

---

## 6. Risk Register

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| ObjC interop breaks | Medium | High | Keep `@objc` annotations, test bridging |
| Circular dependencies | Low | High | Use lazy initialization, protocols |
| Test isolation incomplete | Medium | Medium | Reset mocks in tearDown |
| Performance regression | Low | Low | Benchmark critical paths |
| Team unfamiliarity with patterns | Medium | Medium | Documentation, code reviews |

---

## 7. Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Protocol coverage | 100% of P0/P1 singletons | Code review |
| Test isolation | 0 inter-test failures | CI test runs |
| Code coverage increase | +15% from seams | Coverage reports |
| No regressions | 0 new bugs | QA validation |

---

## 8. Appendix: Complete Protocol Inventory

### New Protocols to Create

| Protocol | File | Priority |
|----------|------|----------|
| `TPPNetworkExecuting` | `Palace/Network/TPPNetworkExecuting.swift` | P0 |
| `TPPBookRegistryProviding` | `Palace/Book/Models/TPPBookRegistryProviding.swift` | P0 |
| `TPPUserAccountProviding` | `Palace/Accounts/User/TPPUserAccountProviding.swift` | P0 |
| `TPPSettingsProviding` | `Palace/Settings/TPPSettingsProviding.swift` | P1 |
| `AudiobookSessionProviding` | `Palace/Audiobooks/AudiobookSessionProviding.swift` | P1 |
| `OPDSFeedCaching` | `Palace/OPDS2/OPDSFeedCaching.swift` | P1 |
| `ClockProviding` | `Palace/Utilities/Clock.swift` | P2 |
| `FileManaging` | `Palace/Utilities/FileManaging.swift` | P2 |
| `KeychainProviding` | `Palace/Keychain/KeychainProviding.swift` | P2 |

### Existing Protocols (Already Testable)

| Protocol | File | Status |
|----------|------|--------|
| `CatalogRepositoryProtocol` | `CatalogRepositoryProtocol.swift` | Has mock |
| `CatalogAPI` | `CatalogAPI.swift` | Has mock |

### Clock / Time Seams

| Seam | File | Notes |
|------|------|-------|
| `CatalogRepository.init(api:now:)` | `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/CatalogRepository.swift` | Injectable `() -> Date` clock used by `isExpired` / `isStaleButUsable` / `isTooOld` and all `CachedFeed` timestamp writes. Production code uses the default `init(api:)` which binds `now = Date.init`. Added to drive stale-while-revalidate boundary tests deterministically (see `PalaceTests/CatalogDomain/CatalogRepositoryStaleWhileRevalidateTests.swift`). |
| `NetworkClient` | `NetworkClient.swift` | Has mock |
| `TPPLibraryAccountsProvider` | `AccountsManager.swift` | Has mock |
| `TPPCurrentLibraryAccountProvider` | `AccountsManager.swift` | Has mock |
| `PDFDocumentProviding` | `PDFDocumentProviding.swift` | Has mock |
| `ImageCacheType` | `ImageCacheType.swift` | Has mock |
| `AnnotationsManager` | `TPPAnnotations.swift` | Has mock |

## 9. Addendum (2026-05): TPPNetworkExecutor full-DI initializer

To support adversarial coverage of the token-refresh + 401 retry-queue
paths in `TPPNetworkExecutor.refreshTokenAndResume`, a new initializer was
added that accepts BOTH a custom `URLSessionConfiguration` (for
`URLProtocol`-based stubbing of the token endpoint and retried requests)
AND an injected `TPPLibraryAccountsProvider` (so per-account credential
reads and `setAuthToken` writes target a test-controlled
`TPPLibraryAccountMock` / `TPPUserAccountMock` instead of the production
singleton via `AppContainer.production().accountsManager`).

```swift
init(credentialsProvider: NYPLBasicAuthCredentialsProvider? = nil,
     cachingStrategy: NYPLCachingStrategy,
     sessionConfiguration: URLSessionConfiguration,
     accountsManager: TPPLibraryAccountsProvider,
     delegateQueue: OperationQueue? = nil)
```

The two pre-existing initializers cover all production callers; combining
them via a third overload avoids forcing every existing caller through a
sessionConfig argument they don't care about. The injected
`accountsManager` flows through `self.accountsManager` for the
token-refresh failure paths (`markCredentialsStale`, signed-in modal
dispatch, retried-request construction). See
`PalaceTests/Network/TokenRefreshAndRetryQueueTests`.

## 10. Addendum (2026-05): TPPSignInBusinessLogic deep-test seam gaps

While adding mutation-killing tests for `TPPSignInBusinessLogic` (see
`PalaceTests/SignInLogic/TPPSignInBusinessLogicOAuthTests.swift`,
`TPPSignInBusinessLogicSignOutTests.swift`, `TPPAgeCheckDeepTests.swift`),
the following seam gaps were identified. **None require production-code
changes today** — each test file works around the gap with techniques
documented inline. The notes here exist so a future seam-sweep PR can
tighten the public test affordance for these surfaces.

### 10.1 `TPPSignInBusinessLogic.handleRedirectURL` — notification observer ordering — RESOLVED (commit gap/signin-seams)

**Resolution:** Added an injectable `notificationCenter` property on
`TPPSignInBusinessLogic` (default `.default`) plus an `@objc
setNotificationCenterForTests(_:)` helper. `oauthLogIn()` and
`handleRedirectURL` now register / remove the observer against
`self.notificationCenter`, allowing tests to drive a hermetic
`NotificationCenter()` for full add → fire → remove verification without
polluting the process-global default center. See new test
`test_oauthRedirectObserver_registersAndRemovesItself_viaInjectedCenter`
in `TPPSignInBusinessLogicOAuthTests`.

### 10.2 `TPPSignInBusinessLogic.getBearerToken` — `TPPNetworkExecutor` is a concrete dependency

`getBearerToken(...)` already accepts an injectable `TPPNetworkExecutor`
argument (default `AppContainer.production().networkExecutor`). The argument
is the concrete class, not a protocol, so token-flow tests have to construct
a real `TPPNetworkExecutor` against a stubbed `URLSessionConfiguration`. This
works (see `TPPSignInBusinessLogicTokenFlowTests`) and stays hermetic via
`HTTPStubURLProtocol`. A `TokenRefreshing` protocol seam would allow a pure
in-memory mock. Low priority.

### 10.3 `TPPAgeCheck` — private `serialQueue` has no flush hook

`TPPAgeCheck.didCompleteAgeCheck(_:)` and `verifyCurrentAccountAgeRequirement(...)`
both hop through a private `DispatchQueue`. `TPPAgeCheckCompletionTests` relies
on the same-queue FIFO guarantee of `serialQueue.async`: both `verify` and
`didCompleteAgeCheck` enqueue onto the queue, and FIFO ordering means the
verify-append always runs before the didComplete-iterate. A
`flushPendingForTests()` hook (or an injected queue) would make this
ordering explicit rather than implicit. Tests are green; this is style.

### 10.4 `TPPSignInBusinessLogic+SignOut.signInGeneration` — associated-object guard

The sign-out race guard stores `signOutSnapshot` and `isSignOutInProgress` via
`objc_getAssociatedObject` / `objc_setAssociatedObject`. Tests in
`TPPSignInBusinessLogicSignOutTests` exercise the race via the public
`cancelPendingSignOut()` lever and observe the **post-condition** (credentials
preserved, Adobe activation preserved). A `var signOutSnapshotForTests: Int`
getter (compiled `#if DEBUG`) would let future tests assert the snapshot's
value across the race window without behaviour changes. Not blocking.
