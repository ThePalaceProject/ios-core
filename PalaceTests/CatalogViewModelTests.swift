import XCTest
import Combine
@testable import Palace

// MARK: - Mock Repository
class MockCatalogRepository: CatalogRepositoryProtocol {
  var shouldFail = false
  var mockFeed: CatalogFeed?
  var loadCallCount = 0
  
  func loadTopLevelCatalog(at url: URL) async throws -> CatalogFeed? {
    loadCallCount += 1
    
    if shouldFail {
      throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mock error"])
    }
    
    return mockFeed
  }
}

// MARK: - CatalogViewModelTests
@MainActor
final class CatalogViewModelTests: XCTestCase {
  private var viewModel: CatalogViewModel!
  private var mockRepository: MockCatalogRepository!
  private var cancellables: Set<AnyCancellable>!
  
  override func setUp() {
    super.setUp()
    mockRepository = MockCatalogRepository()
    viewModel = CatalogViewModel(
      repository: mockRepository,
      topLevelURLProvider: { URL(string: "https://example.com/catalog")! }
    )
    cancellables = Set<AnyCancellable>()
  }
  
  override func tearDown() {
    cancellables?.removeAll()
    viewModel = nil
    mockRepository = nil
    super.tearDown()
  }
  
  // MARK: - Loading Tests
  
  func testLoadSuccess() async {
    // Given
    let mockOPDSFeed = TPPOPDSFeed()
    mockOPDSFeed.type = .acquisitionUngrouped
    
    let mockFeed = CatalogFeed(
      title: "Test Catalog",
      entries: [],
      opdsFeed: mockOPDSFeed
    )
    mockRepository.mockFeed = mockFeed
    
    // When
    await viewModel.load()
    
    // Then
    XCTAssertEqual(mockRepository.loadCallCount, 1)
    XCTAssertFalse(viewModel.isLoading)
    XCTAssertNil(viewModel.errorMessage)
    XCTAssertEqual(viewModel.title, "Test Catalog")
  }
  
  func testLoadFailure() async {
    // Given
    mockRepository.shouldFail = true
    
    // When
    await viewModel.load()
    
    // Then
    XCTAssertEqual(mockRepository.loadCallCount, 1)
    XCTAssertFalse(viewModel.isLoading)
    XCTAssertNotNil(viewModel.errorMessage)
    XCTAssertEqual(viewModel.errorMessage, "Mock error")
  }
  
  func testLoadingStateChanges() async {
    // Given
    let expectation = XCTestExpectation(description: "Loading state changes")
    var loadingStates: [Bool] = []
    
    viewModel.$isLoading
      .sink { isLoading in
        loadingStates.append(isLoading)
        if loadingStates.count == 2 {
          expectation.fulfill()
        }
      }
      .store(in: &cancellables)
    
    mockRepository.mockFeed = CatalogFeed(
      title: "Test",
      entries: [],
      opdsFeed: TPPOPDSFeed()
    )
    
    // When
    await viewModel.load()
    
    // Then
    await fulfillment(of: [expectation], timeout: 1.0)
    XCTAssertEqual(loadingStates, [true, false])
  }
  
  func testDuplicateLoadPrevention() async {
    // Given
    mockRepository.mockFeed = CatalogFeed(
      title: "Test",
      entries: [],
      opdsFeed: TPPOPDSFeed()
    )
    
    // When - Load twice
    await viewModel.load()
    await viewModel.load()
    
    // Then - Should only load once
    XCTAssertEqual(mockRepository.loadCallCount, 1)
  }
  
  // MARK: - Task Cancellation Tests
  
  func testTaskCancellation() async {
    // Given
    let delayedRepository = DelayedMockRepository()
    let delayedViewModel = CatalogViewModel(
      repository: delayedRepository,
      topLevelURLProvider: { URL(string: "https://example.com")! }
    )
    
    // When - Start load and immediately refresh
    let loadTask = Task {
      await delayedViewModel.load()
    }
    
    // Small delay to ensure load starts
    try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
    
    await delayedViewModel.refresh()
    loadTask.cancel()
    
    // Then - Should handle cancellation gracefully
    XCTAssertFalse(delayedViewModel.isLoading)
  }
  
  // MARK: - Memory Tests
  
  func testMemoryLeakPrevention() async {
    // Given
    weak var weakViewModel: CatalogViewModel?
    
    autoreleasepool {
      let tempViewModel = CatalogViewModel(
        repository: mockRepository,
        topLevelURLProvider: { URL(string: "https://example.com")! }
      )
      weakViewModel = tempViewModel
      
      mockRepository.mockFeed = CatalogFeed(
        title: "Test",
        entries: [],
        opdsFeed: TPPOPDSFeed()
      )
      
      Task {
        await tempViewModel.load()
      }
    }
    
    // When - Allow some time for cleanup
    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
    
    // Then - ViewModel should be deallocated
    XCTAssertNil(weakViewModel, "CatalogViewModel should be deallocated")
  }
}

// MARK: - Helper Classes
private class DelayedMockRepository: CatalogRepositoryProtocol {
  func loadTopLevelCatalog(at url: URL) async throws -> CatalogFeed? {
    // Simulate slow network
    try await Task.sleep(nanoseconds: 500_000_000) // 500ms
    return CatalogFeed(title: "Delayed", entries: [], opdsFeed: TPPOPDSFeed())
  }
}

