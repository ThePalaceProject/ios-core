import XCTest
import Combine
@testable import Palace

@MainActor
final class DiscoveryViewModelTests: XCTestCase {
    private var viewModel: DiscoveryViewModel!
    private var mockDiscoveryService: MockDiscoveryService!
    private var mockSearchService: CrossLibrarySearchService!
    private var mockCatalogAPI: CatalogAPIMock!
    private var cancellables = Set<AnyCancellable>()

    override func setUp() {
        super.setUp()
        mockDiscoveryService = MockDiscoveryService()
        mockCatalogAPI = CatalogAPIMock()
        mockSearchService = CrossLibrarySearchService(
            accountsProvider: MockAccountsProvider(),
            catalogAPI: mockCatalogAPI
        )
        viewModel = DiscoveryViewModel(
            discoveryService: mockDiscoveryService,
            searchService: mockSearchService,
            debounceInterval: 0.01 // Fast for tests
        )
    }

    override func tearDown() {
        viewModel = nil
        mockDiscoveryService = nil
        mockSearchService = nil
        mockCatalogAPI = nil
        cancellables.removeAll()
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialState() {
        XCTAssertEqual(viewModel.searchQuery, "")
        XCTAssertTrue(viewModel.recommendations.isEmpty)
        XCTAssertTrue(viewModel.searchResults.isEmpty)
        XCTAssertFalse(viewModel.isSearching)
        XCTAssertFalse(viewModel.isLoadingRecommendations)
        XCTAssertNil(viewModel.selectedMood)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.showError)
    }

    // MARK: - Search Debouncing

    func testSearchDebouncing() async throws {
        // Rapid updates should only trigger one search
        viewModel.updateSearchQuery("h")
        viewModel.updateSearchQuery("he")
        viewModel.updateSearchQuery("hel")
        viewModel.updateSearchQuery("hello")

        // Wait for debounce
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Only the final query should be set
        XCTAssertEqual(viewModel.searchQuery, "hello")
    }

    func testClearSearchResetsState() {
        viewModel.updateSearchQuery("test")
        viewModel.updateSearchQuery("")

        XCTAssertEqual(viewModel.searchQuery, "")
        XCTAssertTrue(viewModel.searchResults.isEmpty)
        XCTAssertFalse(viewModel.isSearching)
    }

    // MARK: - Recommendations

    func testGetRecommendationsSuccess() async throws {
        let expectedRecs = [
            makeRecommendation(id: "1", title: "Book One"),
            makeRecommendation(id: "2", title: "Book Two")
        ]
        mockDiscoveryService.stubbedRecommendations = expectedRecs

        viewModel.getRecommendations()

        // Wait for async completion
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(viewModel.isLoadingRecommendations)
        XCTAssertEqual(viewModel.recommendations.count, 2)
        XCTAssertEqual(viewModel.recommendations[0].title, "Book One")
        XCTAssertEqual(viewModel.recommendations[1].title, "Book Two")
        XCTAssertFalse(viewModel.showError)
    }

    func testGetRecommendationsError() async throws {
        mockDiscoveryService.errorToThrow = DiscoveryError.networkUnavailable

        viewModel.getRecommendations()

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(viewModel.isLoadingRecommendations)
        XCTAssertTrue(viewModel.showError)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    // MARK: - Mood Selection

    func testSelectMoodToggles() {
        viewModel.selectMood(.relaxing)
        XCTAssertEqual(viewModel.selectedMood, .relaxing)

        viewModel.selectMood(.relaxing)
        XCTAssertNil(viewModel.selectedMood)
    }

    func testSelectDifferentMood() {
        viewModel.selectMood(.relaxing)
        XCTAssertEqual(viewModel.selectedMood, .relaxing)

        viewModel.selectMood(.thrilling)
        XCTAssertEqual(viewModel.selectedMood, .thrilling)
    }

    // MARK: - Surprise Me

    func testSurpriseMeClearsSearch() async throws {
        viewModel.updateSearchQuery("something")
        mockDiscoveryService.stubbedRecommendations = [makeRecommendation(id: "1", title: "Surprise")]

        viewModel.surpriseMe()

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(viewModel.searchQuery, "")
        XCTAssertTrue(viewModel.searchResults.isEmpty)
        XCTAssertNil(viewModel.selectedMood)
    }

    // MARK: - AI Availability

    func testIsAIAvailable() {
        mockDiscoveryService.mockIsAvailable = true
        XCTAssertTrue(viewModel.isAIAvailable)

        mockDiscoveryService.mockIsAvailable = false
        XCTAssertFalse(viewModel.isAIAvailable)
    }

    // MARK: - Helpers

    private func makeRecommendation(id: String, title: String) -> DiscoveryRecommendation {
        DiscoveryRecommendation(
            id: id,
            title: title,
            authors: ["Author"],
            summary: "Summary",
            coverImageURL: nil,
            reason: "Great book",
            confidenceScore: 0.9,
            categories: ["Fiction"],
            availability: []
        )
    }
}

// MARK: - Mock Discovery Service

final class MockDiscoveryService: DiscoveryServiceProtocol, @unchecked Sendable {
    var mockIsAvailable: Bool = true
    var isAvailable: Bool { mockIsAvailable }

    var stubbedRecommendations: [DiscoveryRecommendation] = []
    var errorToThrow: Error?
    var getRecommendationsCalled = false

    func getRecommendations(prompt: DiscoveryPrompt) async throws -> [DiscoveryRecommendation] {
        getRecommendationsCalled = true
        if let error = errorToThrow { throw error }
        return stubbedRecommendations
    }
}

// MARK: - Mock Accounts Provider

final class MockAccountsProvider: NSObject, TPPLibraryAccountsProvider {
    var tppAccountUUID: String = "test-uuid"
    var currentAccountId: String? = "test-account"
    var currentAccount: Account?

    func account(_ uuid: String) -> Account? { nil }
}
