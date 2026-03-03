# Test Patterns and Conventions

**Document Version:** 1.0
**Last Updated:** 2026-01-29

---

## 1. Test Organization

### 1.1 Directory Structure

```
PalaceTests/
├── TestSupport/                 # Shared test infrastructure
│   ├── TestDependencyContainer.swift
│   ├── XCTestCase+Extensions.swift
│   ├── Clock.swift
│   └── AsyncTestHelpers.swift
├── Mocks/                       # Mock implementations
│   ├── CatalogRepositoryMock.swift
│   ├── TPPBookRegistryMock.swift
│   └── ...
├── Fixtures/                    # Test data
│   ├── OPDSFeeds/
│   ├── AuthDocs/
│   ├── Manifests/
│   └── Books/
├── <Module>/                    # Module-specific tests
│   ├── SignInLogic/
│   ├── CatalogUI/
│   ├── MyBooks/
│   └── ...
├── Snapshots/                   # Visual regression tests
├── Accessibility/               # Accessibility tests
├── Performance/                 # Performance benchmarks
└── Integration/                 # Cross-module integration tests
```

### 1.2 Naming Conventions

#### Test Files

| Type | Pattern | Example |
|------|---------|---------|
| Unit | `<Class>Tests.swift` | `CatalogViewModelTests.swift` |
| Integration | `<Feature>IntegrationTests.swift` | `SignInIntegrationTests.swift` |
| Snapshot | `<Feature>SnapshotTests.swift` | `BookDetailSnapshotTests.swift` |
| Accessibility | `<Feature>AccessibilityTests.swift` | `CatalogAccessibilityTests.swift` |
| Performance | `<Feature>PerformanceTests.swift` | `RegistryPerformanceTests.swift` |

#### Test Methods

```swift
// Pattern: test<Method>_<Condition>_<Expected>

// Good examples
func testLoad_WithValidURL_CallsRepository()
func testLoad_WithNilURL_DoesNotCallRepository()
func testTokenRefresh_On401Response_RetriesRequest()
func testSignOut_WithActiveDRM_PreservesActivation()

// Avoid
func testLoad()           // Too vague
func testItWorks()        // Meaningless
func test1()              // No description
```

#### Mock Classes

| Type | Pattern | Example |
|------|---------|---------|
| Protocol Mock | `<Protocol>Mock.swift` | `CatalogRepositoryMock.swift` |
| Spy | `<Class>Spy.swift` | `NetworkExecutorSpy.swift` |
| Stub | `<Class>Stub.swift` | `UserAccountStub.swift` |
| Fake | `<Class>Fake.swift` | `KeychainFake.swift` |

---

## 2. Mock Patterns

### 2.1 Protocol-Based Mock

Use when the class under test accepts a protocol dependency.

```swift
// Production protocol
protocol CatalogRepositoryProtocol {
    func loadTopLevelCatalog(at url: URL) async throws -> CatalogFeed?
    func search(query: String, baseURL: URL) async throws -> CatalogFeed?
    func invalidateCache(for url: URL)
}

// Mock implementation
@MainActor
final class CatalogRepositoryMock: CatalogRepositoryProtocol {
    // Configuration
    var loadTopLevelCatalogResult: CatalogFeed?
    var loadTopLevelCatalogError: Error?
    var simulatedDelay: TimeInterval = 0

    // Call tracking
    private(set) var loadTopLevelCatalogCallCount = 0
    private(set) var lastLoadURL: URL?

    func loadTopLevelCatalog(at url: URL) async throws -> CatalogFeed? {
        loadTopLevelCatalogCallCount += 1
        lastLoadURL = url

        if simulatedDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(simulatedDelay * 1_000_000_000))
        }

        if let error = loadTopLevelCatalogError {
            throw error
        }

        return loadTopLevelCatalogResult
    }

    func reset() {
        loadTopLevelCatalogResult = nil
        loadTopLevelCatalogError = nil
        loadTopLevelCatalogCallCount = 0
        lastLoadURL = nil
    }
}
```

**Usage:**

```swift
@MainActor
final class CatalogViewModelTests: XCTestCase {
    private var mockRepository: CatalogRepositoryMock!
    private var viewModel: CatalogViewModel!

    override func setUp() {
        super.setUp()
        mockRepository = CatalogRepositoryMock()
        viewModel = CatalogViewModel(
            repository: mockRepository,
            topLevelURLProvider: { URL(string: "https://test.com")! }
        )
    }

    func testLoad_CallsRepository() async {
        await viewModel.load()
        XCTAssertEqual(mockRepository.loadTopLevelCatalogCallCount, 1)
    }
}
```

### 2.2 HTTPStubURLProtocol (Network Stubbing)

Use for stubbing URLSession network requests.

```swift
// Location: PalaceTests/HTTPStubURLProtocol.swift

final class HTTPStubURLProtocol: URLProtocol {
    struct StubbedResponse {
        let statusCode: Int
        let headers: [String: String]?
        let body: Data?
    }

    static func register(_ handler: @escaping (URLRequest) -> StubbedResponse?)
    static func reset()
}
```

**Usage:**

```swift
final class NetworkClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.reset()
    }

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        super.tearDown()
    }

    func testGET_Returns200_ParsesData() async throws {
        // Arrange
        let expectedData = """
        {"title": "Test Catalog"}
        """.data(using: .utf8)!

        HTTPStubURLProtocol.register { request in
            guard request.url?.host == "api.example.com" else { return nil }
            return .init(statusCode: 200, headers: ["Content-Type": "application/json"], body: expectedData)
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = URLSessionNetworkClient(session: session)

        // Act
        let response = try await client.get(URL(string: "https://api.example.com/catalog")!)

        // Assert
        XCTAssertEqual(response.statusCode, 200)
    }
}
```

### 2.3 Spy Pattern

Use when you need to verify interactions without changing behavior.

```swift
final class NetworkExecutorSpy: TPPNetworkExecutor {
    private(set) var getCallCount = 0
    private(set) var capturedURLs: [URL] = []

    override func GET(_ reqURL: URL,
                      useTokenIfAvailable: Bool = true,
                      completion: @escaping (NYPLResult<Data>) -> Void) {
        getCallCount += 1
        capturedURLs.append(reqURL)
        super.GET(reqURL, useTokenIfAvailable: useTokenIfAvailable, completion: completion)
    }
}
```

### 2.4 Fake Pattern

Use for simplified implementations that work correctly but are simpler than production.

```swift
final class KeychainFake: TPPKeychainProviding {
    private var storage: [String: Data] = [:]

    func set(_ data: Data, forKey key: String) throws {
        storage[key] = data
    }

    func get(forKey key: String) throws -> Data? {
        return storage[key]
    }

    func delete(forKey key: String) throws {
        storage[key] = nil
    }

    func clear() {
        storage.removeAll()
    }
}
```

---

## 3. Async Testing Patterns

### 3.1 Testing async/await Functions

```swift
@MainActor
final class CatalogViewModelTests: XCTestCase {

    func testLoad_SetsIsLoading() async {
        let viewModel = createViewModel()

        // Use expectation for @Published property observation
        let expectation = XCTestExpectation(description: "isLoading becomes true")

        viewModel.$isLoading
            .dropFirst()  // Skip initial value
            .sink { isLoading in
                if isLoading {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        await viewModel.load()

        await fulfillment(of: [expectation], timeout: 1.0)
    }

    func testLoad_WithError_SetsErrorMessage() async {
        mockRepository.loadTopLevelCatalogError = TestError.networkError

        await viewModel.load()

        XCTAssertNotNil(viewModel.errorMessage)
    }
}
```

### 3.2 Testing Combine Publishers

```swift
final class PublisherTests: XCTestCase {
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        cancellables = Set<AnyCancellable>()
    }

    override func tearDown() {
        cancellables = nil
        super.tearDown()
    }

    func testPublisher_EmitsExpectedValues() {
        let expectation = XCTestExpectation(description: "Publisher emits values")
        var receivedValues: [String] = []

        sut.valuePublisher
            .sink { value in
                receivedValues.append(value)
                if receivedValues.count == 3 {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        sut.triggerChanges()

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(receivedValues, ["first", "second", "third"])
    }
}
```

### 3.3 Testing @MainActor Code

```swift
// Mark the entire test class with @MainActor
@MainActor
final class ViewModelTests: XCTestCase {

    // All test methods run on main actor
    func testPropertyUpdate() {
        viewModel.updateTitle("New Title")
        XCTAssertEqual(viewModel.title, "New Title")
    }
}

// Or use Task for individual assertions
final class MixedActorTests: XCTestCase {

    func testFromBackgroundThread() async {
        await MainActor.run {
            viewModel.updateTitle("New Title")
            XCTAssertEqual(viewModel.title, "New Title")
        }
    }
}
```

---

## 4. Snapshot Testing Patterns

### 4.1 Basic Snapshot Test

```swift
import SnapshotTesting
import SwiftUI
import XCTest
@testable import Palace

final class BookDetailSnapshotTests: XCTestCase {

    func testBookDetail_LightMode() {
        let book = TPPBookMocker.snapshotEPUB()
        let view = BookDetailView(book: book)
            .frame(width: 375, height: 812)

        assertSnapshot(matching: view, as: .image)
    }

    func testBookDetail_DarkMode() {
        let book = TPPBookMocker.snapshotEPUB()
        let view = BookDetailView(book: book)
            .frame(width: 375, height: 812)
            .environment(\.colorScheme, .dark)

        assertSnapshot(matching: view, as: .image)
    }
}
```

### 4.2 Snapshot Configuration

```swift
// PalaceTests/Snapshots/SnapshotTestConfiguration.swift

import SnapshotTesting

extension Snapshotting where Value: View, Format == UIImage {
    static var standardImage: Snapshotting {
        return .image(
            precision: 0.99,
            perceptualPrecision: 0.98,
            layout: .device(config: .iPhone13)
        )
    }
}

// Usage
assertSnapshot(matching: view, as: .standardImage)
```

### 4.3 Multi-Device Snapshots

```swift
func testCatalog_MultipleDevices() {
    let view = CatalogView()

    let configs: [(name: String, config: ViewImageConfig)] = [
        ("iPhone_SE", .iPhoneSe),
        ("iPhone_13", .iPhone13),
        ("iPhone_13_Pro_Max", .iPhone13ProMax),
        ("iPad", .iPadMini)
    ]

    for (name, config) in configs {
        assertSnapshot(
            matching: view,
            as: .image(layout: .device(config: config)),
            named: name
        )
    }
}
```

---

## 5. Accessibility Testing Patterns

### 5.1 Label Verification

```swift
final class CatalogAccessibilityTests: XCTestCase {

    func testCatalogLaneRow_HasAccessibilityLabel() {
        let books = [TPPBookMocker.snapshotEPUB()]
        let lane = CatalogLaneRowView(lane: CatalogLaneModel(title: "Fiction", books: books, moreURL: nil))

        let view = UIHostingController(rootView: lane).view!

        // Find all interactive elements
        let buttons = view.findAllViews(ofType: UIButton.self)

        for button in buttons {
            XCTAssertFalse(
                button.accessibilityLabel?.isEmpty ?? true,
                "Button at \(button.frame) missing accessibility label"
            )
        }
    }
}
```

### 5.2 VoiceOver Order Verification

```swift
func testSignInForm_VoiceOverOrder() {
    let view = SignInView()
    let hostingController = UIHostingController(rootView: view)
    hostingController.loadViewIfNeeded()

    let elements = hostingController.view.accessibilityElements ?? []
    let labels = elements.compactMap { ($0 as? UIAccessibilityElement)?.accessibilityLabel }

    XCTAssertEqual(labels, [
        "Library selector",
        "Username field",
        "Password field",
        "Sign in button"
    ])
}
```

---

## 6. Integration Testing Patterns

### 6.1 Multi-Component Integration

```swift
final class SignInToCatalogIntegrationTests: XCTestCase {
    private var networkMock: HTTPStubURLProtocol.Type!
    private var accountsManager: AccountsManagerMock!
    private var catalogRepository: CatalogRepository!

    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.reset()

        // Stub authentication endpoint
        HTTPStubURLProtocol.register { request in
            guard request.url?.path == "/auth/token" else { return nil }
            return .init(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: TokenFixtures.validTokenResponse
            )
        }

        // Stub catalog endpoint
        HTTPStubURLProtocol.register { request in
            guard request.url?.path == "/catalog" else { return nil }
            return .init(
                statusCode: 200,
                headers: ["Content-Type": "application/atom+xml"],
                body: CatalogFixtures.validOPDSFeed
            )
        }

        // Create real components with stubbed network
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let networkClient = URLSessionNetworkClient(session: session)

        catalogRepository = CatalogRepository(api: DefaultCatalogAPI(networkClient: networkClient))
    }

    func testSignIn_ThenLoadCatalog_Succeeds() async throws {
        // Sign in
        let signInLogic = TPPSignInBusinessLogic(/* injected dependencies */)
        try await signInLogic.signIn(username: "test", password: "pass")

        // Load catalog
        let feed = try await catalogRepository.loadTopLevelCatalog(at: URL(string: "https://test.com/catalog")!)

        XCTAssertNotNil(feed)
        XCTAssertFalse(feed!.entries.isEmpty)
    }
}
```

### 6.2 State Isolation

```swift
final class IntegrationTestBase: XCTestCase {

    override func setUp() {
        super.setUp()
        resetAllState()
    }

    override func tearDown() {
        resetAllState()
        super.tearDown()
    }

    private func resetAllState() {
        // Clear network stubs
        HTTPStubURLProtocol.reset()

        // Clear caches
        URLCache.shared.removeAllCachedResponses()

        // Reset UserDefaults for tests
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }

        // Clear keychain (fake)
        KeychainFake.shared.clear()

        // Reset singletons (when protocols extracted)
        TestDependencyContainer.reset()
    }
}
```

---

## 7. Performance Testing Patterns

### 7.1 Measure Block

```swift
final class RegistryPerformanceTests: XCTestCase {

    func testRegistryLoad_1000Books() {
        let registry = TPPBookRegistry()
        let books = (0..<1000).map { TPPBookMocker.book(id: "book-\($0)") }

        measure {
            for book in books {
                registry.add(book)
            }
        }
    }

    func testRegistryLoad_FromDisk() {
        // Setup: Save 1000 books to disk
        let registry = TPPBookRegistry()
        for i in 0..<1000 {
            registry.add(TPPBookMocker.book(id: "book-\(i)"))
        }
        registry.save()

        // Measure load time
        measure {
            let newRegistry = TPPBookRegistry()
            newRegistry.load()
        }
    }
}
```

### 7.2 Memory Measurement

```swift
func testChapterParsing_MemoryEfficient() {
    let options = XCTMeasureOptions()
    options.invocationOptions = [.manuallyStart, .manuallyStop]

    measure(metrics: [XCTMemoryMetric()], options: options) {
        autoreleasepool {
            startMeasuring()
            let parser = ChapterParsingOptimizer()
            _ = parser.parse(largeManifest)
            stopMeasuring()
        }
    }
}
```

---

## 8. Test Data Management

### 8.1 Book Mocker

```swift
// PalaceTests/TestSupport/TPPBookMocker.swift

struct TPPBookMocker {

    static func snapshotEPUB() -> TPPBook {
        return TPPBook(
            identifier: "test-epub-1",
            title: "Test EPUB Book",
            authors: [TPPBookAuthor(name: "Test Author")],
            coverURL: URL(string: "https://example.com/cover.jpg"),
            acquisitions: [.borrow(url: URL(string: "https://example.com/borrow")!)],
            format: .epub
        )
    }

    static func snapshotAudiobook() -> TPPBook {
        return TPPBook(
            identifier: "test-audiobook-1",
            title: "Test Audiobook",
            authors: [TPPBookAuthor(name: "Test Author")],
            coverURL: URL(string: "https://example.com/cover.jpg"),
            acquisitions: [.borrow(url: URL(string: "https://example.com/borrow")!)],
            format: .audiobook
        )
    }

    static func book(id: String, state: TPPBookState = .unowned) -> TPPBook {
        var book = snapshotEPUB()
        book.identifier = id
        return book
    }
}
```

### 8.2 Fixture Management

```swift
// PalaceTests/Fixtures/FixtureLoader.swift

enum FixtureLoader {

    static func load(_ name: String, extension ext: String = "json") -> Data {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
            fatalError("Fixture \(name).\(ext) not found")
        }
        return try! Data(contentsOf: url)
    }

    static func loadJSON<T: Decodable>(_ name: String, as type: T.Type) -> T {
        let data = load(name, extension: "json")
        return try! JSONDecoder().decode(type, from: data)
    }
}

private class BundleToken {}

// Usage
let feed = FixtureLoader.loadJSON("opds2_catalog", as: OPDS2CatalogsFeed.self)
```

---

## 9. CI Integration

### 9.1 Test Configuration for CI

```yaml
# .github/workflows/unit-testing.yml
- name: Run Tests
  run: |
    xcodebuild test \
      -workspace Palace.xcworkspace \
      -scheme Palace \
      -destination 'platform=iOS Simulator,name=iPhone 16' \
      -enableCodeCoverage YES \
      -resultBundlePath TestResults.xcresult \
      -parallel-testing-enabled YES \
      -maximum-concurrent-test-simulator-destinations 4
```

### 9.2 Test Filtering

```swift
// Skip slow tests in CI quick checks
func testSlowIntegration() throws {
    try XCTSkipIf(ProcessInfo.processInfo.environment["CI_QUICK"] == "true")
    // ... slow test
}

// Skip tests requiring real keychain
func testRealKeychain() throws {
    try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil)
    // ... real keychain test
}
```

---

## 10. Common Pitfalls and Solutions

### 10.1 Flaky Async Tests

**Problem:** Tests pass locally but fail in CI due to timing.

**Solution:** Use explicit expectations with appropriate timeouts.

```swift
// Bad
func testAsync() async {
    await viewModel.load()
    XCTAssertTrue(viewModel.isLoaded) // May fail if async completion not awaited
}

// Good
func testAsync() async {
    let expectation = XCTestExpectation(description: "Load completes")

    viewModel.$isLoaded
        .filter { $0 }
        .sink { _ in expectation.fulfill() }
        .store(in: &cancellables)

    await viewModel.load()
    await fulfillment(of: [expectation], timeout: 5.0)
}
```

### 10.2 Singleton State Leakage

**Problem:** Tests affect each other through shared singletons.

**Solution:** Use protocol extraction and dependency injection.

```swift
// Bad: Direct singleton access
class MyClass {
    func doWork() {
        AccountsManager.shared.loadCatalogs { _ in }
    }
}

// Good: Injected dependency
class MyClass {
    private let accountsProvider: TPPLibraryAccountsProvider

    init(accountsProvider: TPPLibraryAccountsProvider = AccountsManager.shared) {
        self.accountsProvider = accountsProvider
    }
}
```

### 10.3 Network Tests in CI

**Problem:** Real network calls fail or are slow in CI.

**Solution:** Always use HTTPStubURLProtocol.

```swift
// Setup in test class
override func setUp() {
    super.setUp()

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HTTPStubURLProtocol.self]

    // Fail fast for unstubbed requests
    HTTPStubURLProtocol.register { request in
        XCTFail("Unexpected network request: \(request.url!)")
        return .init(statusCode: 500, headers: nil, body: nil)
    }
}
```
