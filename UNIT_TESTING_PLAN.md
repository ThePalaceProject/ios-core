# Palace iOS Unit Testing Migration Plan

This document outlines the strategy for improving test coverage across the Palace iOS codebase and establishes **mandatory TDD requirements** for all agents working on bugs and features.

## Table of Contents

1. [Current State](#current-state)
2. [Target State](#target-state)
3. [TDD Requirements for Agents](#tdd-requirements-for-agents)
4. [Testing Guidelines](#testing-guidelines)
5. [Migration Phases](#migration-phases)
6. [Priority Classes for Coverage](#priority-classes-for-coverage)
7. [Mock Infrastructure](#mock-infrastructure)
8. [CI/CD Integration](#cicd-integration)

---

## Current State

### Coverage Summary (as of January 2026)

| Layer | Current Coverage | Target |
|-------|-----------------|--------|
| ViewModels | ~60% | 85% |
| Business Logic | ~50% | 90% |
| Utilities | ~40% | 80% |
| Models | ~70% | 95% |
| Network Layer | ~30% | 75% |

### Well-Tested Areas
- `BookButtonMapper` / `BookButtonState`
- `CatalogFilter` / `CatalogFilterGroup` / `CatalogLaneModel`
- `HoldsViewModel` (with DI)
- `BookCellModelCache`
- `FacetViewModel`
- Hold badge count logic

### Areas Needing Improvement
- `MyBooksDownloadCenter` - Complex download logic
- `TPPBookRegistry` - Core state management
- `AccountsManager` - Account switching logic
- `TPPAnnotations` - Server sync logic
- PDF/EPUB reader business logic
- Audiobook playback logic

---

## Target State

### Coverage Goals by Q2 2026

```
ViewModels:        85% coverage (from 60%)
Business Logic:    90% coverage (from 50%)
Utilities:         80% coverage (from 40%)
Models:            95% coverage (from 70%)
Network Layer:     75% coverage (from 30%)
```

### Quality Goals
- Zero flaky tests in CI
- All tests run in < 2 minutes
- No network dependencies in unit tests
- 100% of new code has corresponding tests

---

## TDD Requirements for Agents

### MANDATORY: Test-Driven Development Protocol

All agents (AI assistants) working on this codebase **MUST** follow TDD for:
- Bug fixes
- New features
- Refactoring existing code

### TDD Workflow for Bug Fixes

```
1. FIRST: Write a failing test that reproduces the bug
   - Include ticket number in test comment (e.g., "/// Regression test for PP-1234")
   - Test MUST fail before the fix is applied

2. THEN: Implement the fix

3. FINALLY: Verify the test passes

4. COMMIT: Include both test and fix in the same PR
```

**Example:**

```swift
/// Regression test for PP-1234: Download button shows after book is returned
/// This test verifies the fix by ensuring state updates propagate to UI.
func testPP1234_BookReturn_UpdatesButtonState() {
  // Arrange: Book in downloaded state
  let mockRegistry = TPPBookRegistryMock()
  let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
  mockRegistry.addBook(book, state: .downloadSuccessful)
  
  let viewModel = MyBooksViewModel(registry: mockRegistry)
  
  // Act: Return the book
  viewModel.returnBook(book)
  
  // Assert: Button state reflects the change
  let buttonState = BookButtonMapper.map(
    registryState: mockRegistry.state(for: book.identifier),
    availability: nil,
    isProcessingDownload: false
  )
  XCTAssertNotEqual(buttonState, .downloadSuccessful)
}
```

### TDD Workflow for New Features

```
1. FIRST: Write tests that define the expected behavior
   - Test the happy path
   - Test edge cases
   - Test error conditions

2. THEN: Implement the feature to make tests pass

3. FINALLY: Refactor while keeping tests green

4. COMMIT: Tests and implementation together
```

### Agent Checklist Before Committing

- [ ] New/modified code has corresponding tests
- [ ] Tests use real production classes (not testing mocks)
- [ ] Mocks are only used for dependency injection
- [ ] No network calls in tests
- [ ] Tests are deterministic (no random data, fixed dates)
- [ ] Bug fix tests include ticket reference
- [ ] Tests follow naming convention: `test[MethodOrFeature]_[Scenario]_[ExpectedResult]`

---

## Testing Guidelines

### What to Test

#### DO Test:
- **Real production classes** - ViewModels, Models, Services, Utilities
- **Business logic** - State transitions, calculations, validations
- **Error handling** - Network failures, invalid input, edge cases
- **Encoding/decoding** - JSON serialization, model parsing
- **Computed properties** - Derived values, formatting

#### DON'T Test:
- Mock implementations themselves
- Basic Swift operations (Set.insert, Array.filter)
- UIKit/SwiftUI framework behavior
- Third-party library internals

### Test Structure

```swift
// Test file naming: [ClassName]Tests.swift
// Test class naming: [ClassName]Tests

final class MyViewModelTests: XCTestCase {
  
  // MARK: - Properties
  private var sut: MyViewModel!  // System Under Test
  private var mockDependency: MockDependency!
  
  // MARK: - Setup/Teardown
  override func setUp() {
    super.setUp()
    mockDependency = MockDependency()
    sut = MyViewModel(dependency: mockDependency)
  }
  
  override func tearDown() {
    sut = nil
    mockDependency = nil
    super.tearDown()
  }
  
  // MARK: - Tests
  
  /// Tests that [specific behavior] when [condition]
  func testMethodName_WhenCondition_ExpectedResult() {
    // Arrange
    let input = "test input"
    
    // Act
    let result = sut.methodUnderTest(input)
    
    // Assert
    XCTAssertEqual(result, expectedValue)
  }
}
```

### Async Testing Patterns

```swift
// For async/await methods
func testAsyncMethod_ReturnsExpectedResult() async {
  let result = await sut.asyncMethod()
  XCTAssertEqual(result, expected)
}

// For Combine publishers
func testPublisher_EmitsExpectedValue() {
  let expectation = XCTestExpectation(description: "Publisher emits")
  
  sut.$publishedProperty
    .dropFirst()
    .sink { value in
      XCTAssertEqual(value, expected)
      expectation.fulfill()
    }
    .store(in: &cancellables)
  
  sut.triggerChange()
  
  wait(for: [expectation], timeout: 1.0)
}
```

### Mock Usage Rules

```swift
// CORRECT: Mock isolates the real class under test
func testViewModel_LoadsData() {
  let mockRepository = CatalogRepositoryMock()
  let viewModel = CatalogViewModel(repository: mockRepository)  // Real class
  
  XCTAssertNotNil(viewModel.lanes)
}

// WRONG: Testing the mock itself
func testMockRepository_ReturnsData() {
  let mock = CatalogRepositoryMock()
  mock.searchResult = someFeed
  
  XCTAssertEqual(mock.searchResult, someFeed)  // Tests nothing useful!
}
```

---

## Migration Phases

### Phase 1: Foundation (Current - Q1 2026)

**Goal:** Establish testing infrastructure and patterns

- [x] Create `TPPBookMocker` with deterministic test data
- [x] Create `TPPBookRegistryMock` with full protocol support
- [x] Create `CatalogRepositoryMock` for catalog tests
- [x] Create `MockImageCache` for image-related tests
- [x] Document testing standards in `TESTING.md`
- [x] Create this migration plan

### Phase 2: ViewModel Coverage (Q1 2026)

**Goal:** 85% coverage on all ViewModels

| ViewModel | Status | Owner |
|-----------|--------|-------|
| `BookDetailViewModel` | In Progress | - |
| `MyBooksViewModel` | In Progress | - |
| `CatalogViewModel` | Done | - |
| `HoldsViewModel` | Done | - |
| `AccountDetailViewModel` | In Progress | - |
| `CatalogSearchViewModel` | Done | - |
| `CatalogLaneMoreViewModel` | Done | - |
| `FacetViewModel` | Done | - |
| `SettingsViewModel` | Pending | - |
| `ReaderSettingsViewModel` | Pending | - |

### Phase 3: Business Logic Coverage (Q2 2026)

**Goal:** 90% coverage on core business logic

| Class | Priority | Status |
|-------|----------|--------|
| `TPPBookRegistry` | Critical | Pending |
| `MyBooksDownloadCenter` | Critical | Pending |
| `AccountsManager` | High | Pending |
| `TPPAnnotations` | High | Pending |
| `BookButtonMapper` | Done | - |
| `BookCellModelCache` | Done | - |
| `AudiobookBookmarkBusinessLogic` | Medium | Pending |
| `TPPLastReadPositionSynchronizer` | Medium | Pending |

### Phase 4: Network & Integration (Q2-Q3 2026)

**Goal:** 75% coverage on network layer with mocked responses

| Component | Status |
|-----------|--------|
| `TPPNetworkExecutor` | Pending |
| `TPPOPDSFeedFetcher` | Pending |
| `TPPAnnotationsManager` | Pending |
| `CatalogRepository` | Partial |

---

## Priority Classes for Coverage

### Critical Priority (Must have 90%+ coverage)

These classes affect core user flows and are high-risk for regressions:

1. **`TPPBookRegistry`** - Central state management
   - State transitions
   - Book addition/removal
   - State persistence
   - Publisher emissions

2. **`MyBooksDownloadCenter`** - Download management
   - Download initiation
   - Progress tracking
   - Cancellation
   - Error handling

3. **`BookButtonMapper`** - UI state mapping
   - All state combinations
   - Availability handling
   - Processing states

### High Priority (Must have 80%+ coverage)

4. **`AccountsManager`** - Multi-library support
5. **`TPPAnnotations`** - Bookmark sync
6. **`HoldsViewModel`** - Hold management
7. **`CatalogViewModel`** - Catalog browsing

### Medium Priority (Target 70%+ coverage)

8. **Reader business logic**
9. **Audiobook playback logic**
10. **Settings persistence**

---

## Mock Infrastructure

### Available Mocks

Located in `PalaceTests/Mocks/`:

| Mock | Purpose | Supports |
|------|---------|----------|
| `TPPBookRegistryMock` | Book state management | Full protocol, publishers |
| `CatalogRepositoryMock` | Catalog API | Search, load, cache |
| `MockImageCache` | Image caching | TenPrint covers |
| `TPPBookMocker` | Test book creation | All distributor types |

### Creating New Mocks

When creating a new mock:

1. **Implement the full protocol** - Don't skip methods
2. **Add tracking properties** - Call counts, last parameters
3. **Support error injection** - For testing error paths
4. **Add to Mocks/ directory** - Keep organized
5. **Document in this file** - Update the table above

**Template:**

```swift
@MainActor
final class MyServiceMock: MyServiceProtocol {
  
  // MARK: - Tracking
  var methodCallCount = 0
  var lastParameter: String?
  
  // MARK: - Configuration
  var resultToReturn: Result?
  var errorToThrow: Error?
  
  // MARK: - Protocol Implementation
  func myMethod(param: String) async throws -> Result {
    methodCallCount += 1
    lastParameter = param
    
    if let error = errorToThrow {
      throw error
    }
    return resultToReturn ?? defaultResult
  }
  
  // MARK: - Helpers
  func reset() {
    methodCallCount = 0
    lastParameter = nil
    resultToReturn = nil
    errorToThrow = nil
  }
}
```

---

## CI/CD Integration

### Test Requirements for PR Merge

All PRs must pass:

1. **Unit tests** - All tests green
2. **Coverage check** - No decrease in coverage
3. **Lint check** - SwiftLint passes

### CI Test Configuration

Tests should:
- Run on iOS Simulator (iPhone 14 Pro, iOS 16.1+)
- Complete in < 2 minutes
- Have no network dependencies
- Be deterministic (same result every run)

### Flaky Test Policy

If a test is flaky:

1. **Immediately quarantine** - Skip with `XCTSkip("Flaky - PP-XXXX")`
2. **Create ticket** - Document the flakiness
3. **Fix within 1 sprint** - Or delete the test
4. **Never ignore** - Flaky tests erode confidence

---

## Quick Reference for Agents

### Before Starting Any Task

```
1. Check if the area has existing tests
2. Read TESTING.md for standards
3. Identify what needs to be tested
```

### For Bug Fixes

```
1. Write failing test with ticket # in comment
2. Verify test fails
3. Implement fix
4. Verify test passes
5. Run full test suite
6. Commit test + fix together
```

### For New Features

```
1. Write tests for expected behavior
2. Include happy path + edge cases + errors
3. Implement feature
4. Refactor with tests green
5. Run full test suite
6. Commit tests + feature together
```

### Test Naming Convention

```
test[Unit]_[Scenario]_[ExpectedBehavior]

Examples:
- testButtonMapper_DownloadingState_ReturnsInProgress
- testViewModel_NilURL_DoesNotLoad
- testCache_MemoryWarning_ClearsEntries
```

### Common Test Patterns

```swift
// Testing state changes
mockRegistry.setState(.downloading, for: bookId)
XCTAssertEqual(viewModel.buttonState, .downloadInProgress)

// Testing async operations
await viewModel.load()
XCTAssertFalse(viewModel.isLoading)

// Testing error handling
mockRepository.errorToThrow = TestError.networkError
await viewModel.load()
XCTAssertNotNil(viewModel.errorMessage)

// Testing publishers
let exp = expectation(description: "Publisher")
viewModel.$state.dropFirst().sink { _ in exp.fulfill() }.store(in: &cancellables)
viewModel.triggerChange()
wait(for: [exp], timeout: 1.0)
```

---

## Appendix: Test File Locations

```
PalaceTests/
├── ViewModels/              # ViewModel unit tests
│   ├── BookDetailViewModelTests.swift
│   ├── HoldsViewModelTests.swift
│   ├── AccountDetailViewModelTests.swift
│   ├── FacetViewModelTests.swift
│   ├── CatalogSearchViewModelTests.swift
│   └── CatalogLaneMoreViewModelTests.swift
├── CatalogUI/               # Catalog-related tests
│   └── CatalogViewModelTests.swift
├── MyBooks/                 # MyBooks tests
│   └── MyBooksViewModelTests.swift
├── Performance/             # Performance & cache tests
│   └── BookCellModelCacheTests.swift
├── Mocks/                   # Shared mock implementations
│   ├── TPPBookRegistryMock.swift
│   ├── CatalogRepositoryMock.swift
│   └── MockImageCache.swift
├── Network/                 # Network layer tests
├── Audiobook/               # Audiobook tests
├── Reader/                  # EPUB reader tests
├── PDF/                     # PDF reader tests
└── OPDS2/                   # OPDS2 feed tests
```

---

*Last updated: January 2026*
*Maintainer: Palace iOS Team*
