//
//  FacetViewModelTests.swift
//  PalaceTests
//
//  Tests for FacetViewModel which manages sorting facets in My Books.
//

import XCTest
import Combine
@testable import Palace

@MainActor
final class FacetViewModelTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        cancellables = []
    }

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    /// Test factory: FacetViewModel's `accountsManager` is a required dep.
    /// Tests that don't care about account behavior get a fresh, isolated
    /// AccountsManager via `makeTestAppContainer()` so test-pollution can't
    /// leak account state across tests.
    private func makeViewModel(groupName: String, facets: [Facet]) -> FacetViewModel {
        let appContainer = makeTestAppContainer()
        return FacetViewModel(groupName: groupName, facets: facets, accountsManager: appContainer.accountsManager)
    }

    // MARK: - Facet Enum Tests

    func testFacetRawValues() {
        // Raw values drive URL query params and UserDefaults keys — wrong values break persistence.
        // Verify round-trip: a Facet constructed from its raw value must equal the original.
        XCTAssertEqual(Facet(rawValue: "author"), .author,
                       "Facet.author must be recoverable from raw value 'author' — used in persistence")
        XCTAssertEqual(Facet(rawValue: "title"), .title,
                       "Facet.title must be recoverable from raw value 'title' — used in persistence")
        // Raw values must be distinct so that UserDefaults can distinguish the two facets
        XCTAssertNotEqual(Facet.author.localizedString, Facet.title.localizedString,
                          "Author and Title facets must have distinct localized display strings")
        XCTAssertNil(Facet(rawValue: "nonexistent"),
                     "An invalid raw value must return nil, guarding against corrupt UserDefaults")
    }

    func testFacetLocalizedStrings() {
        // Verify localized strings are not empty
        XCTAssertFalse(Facet.author.localizedString.isEmpty)
        XCTAssertFalse(Facet.title.localizedString.isEmpty)

        // Verify they match expected strings
        XCTAssertEqual(Facet.author.localizedString, Strings.FacetView.author)
        XCTAssertEqual(Facet.title.localizedString, Strings.FacetView.title)
    }

    // MARK: - Initialization Tests

    func testInitWithAuthorAndTitleFacets() {
        let viewModel = makeViewModel(groupName: "My Books", facets: [.author, .title])

        XCTAssertEqual(viewModel.groupName, "My Books")
        XCTAssertEqual(viewModel.facets, [.author, .title])
        XCTAssertEqual(viewModel.activeSort, .author, "Active sort should default to first facet")
    }

    func testInitWithTitleFirst() {
        let viewModel = makeViewModel(groupName: "Library", facets: [.title, .author])

        XCTAssertEqual(viewModel.activeSort, .title, "Active sort should default to first facet")
        XCTAssertEqual(viewModel.facets.first, .title, "First facet in the array must be .title")
        XCTAssertEqual(viewModel.groupName, "Library", "Group name must be preserved from initializer")
    }

    func testInitWithSingleFacet() {
        let viewModel = makeViewModel(groupName: "Test", facets: [.author])

        XCTAssertEqual(viewModel.facets.count, 1)
        XCTAssertEqual(viewModel.activeSort, .author)
    }

    // MARK: - Published Property Tests

    func testGroupNamePublished() {
        let viewModel = makeViewModel(groupName: "Initial", facets: [.author, .title])

        let expectation = XCTestExpectation(description: "groupName should publish changes")

        viewModel.$groupName
            .dropFirst()
            .sink { newValue in
                XCTAssertEqual(newValue, "Updated")
                expectation.fulfill()
            }
            .store(in: &cancellables)

        viewModel.groupName = "Updated"

        wait(for: [expectation], timeout: 1.0)
    }

    func testActiveSortPublished() {
        let viewModel = makeViewModel(groupName: "Test", facets: [.author, .title])

        let expectation = XCTestExpectation(description: "activeSort should publish changes")

        viewModel.$activeSort
            .dropFirst()
            .sink { newValue in
                XCTAssertEqual(newValue, .title)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        viewModel.activeSort = .title

        wait(for: [expectation], timeout: 1.0)
    }

    func testFacetsArrayPublished() {
        let viewModel = makeViewModel(groupName: "Test", facets: [.author])

        let expectation = XCTestExpectation(description: "facets should publish changes")

        viewModel.$facets
            .dropFirst()
            .sink { newValue in
                XCTAssertEqual(newValue.count, 2)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        viewModel.facets = [.author, .title]

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Account URL Tests

    func testCurrentAccountURLWithNilAccount() {
        let vm = makeViewModel(groupName: "Test", facets: [.author, .title])
        // The init populates from makeTestAppContainer().accountsManager — clear to test nil path
        vm.currentAccount = nil
        vm.logo = nil

        // With no account, all account-derived computed properties must be nil
        XCTAssertNil(vm.currentAccountURL, "currentAccountURL must be nil when currentAccount is nil")
        XCTAssertNil(vm.logo, "logo must be nil when currentAccount is nil")
        XCTAssertFalse(vm.showAccountScreen, "showAccountScreen must remain false in the nil-account state")
    }

    // MARK: - Show Account Screen Tests

    func testShowAccountScreenInitiallyFalse() {
        let viewModel = makeViewModel(groupName: "Test", facets: [.author, .title])

        // showAccountScreen defaults to false regardless of account state
        XCTAssertFalse(viewModel.showAccountScreen)

        // Clear account to test nil-account derived properties
        viewModel.currentAccount = nil
        viewModel.logo = nil
        XCTAssertNil(viewModel.currentAccountURL, "currentAccountURL must be nil when no account is set")
    }

    func testShowAccountScreenToggle() {
        let viewModel = makeViewModel(groupName: "Test", facets: [.author, .title])

        // Track the state before and after toggling
        let initialState = viewModel.showAccountScreen
        XCTAssertFalse(initialState, "showAccountScreen must default to false before any interaction")

        viewModel.showAccountScreen = true
        let afterEnable = viewModel.showAccountScreen
        viewModel.showAccountScreen = false
        let afterDisable = viewModel.showAccountScreen

        // The toggled-on state must differ from initial (false) and toggled-off state
        XCTAssertTrue(afterEnable, "showAccountScreen must be true after setting to true")
        XCTAssertFalse(afterDisable, "showAccountScreen must return to false after reset")
        XCTAssertEqual(viewModel.activeSort, .author,
                       "Toggling showAccountScreen must not change activeSort")
    }

    // MARK: - Logo Tests

    func testLogoInitiallyNilWithoutAccount() {
        let viewModel = makeViewModel(groupName: "Test", facets: [.author, .title])
        // Clear state populated by init's updateAccount() call
        viewModel.currentAccount = nil
        viewModel.logo = nil

        // With no account, logo and URL must both be nil
        XCTAssertNil(viewModel.logo, "logo must be nil when no currentAccount is set")
        XCTAssertNil(viewModel.currentAccountURL, "currentAccountURL must be nil when no currentAccount is set")
        XCTAssertNil(viewModel.currentAccount, "currentAccount must remain nil after explicit nil assignment")
    }

    // MARK: - Edge Case Tests

    func testChangingSortMultipleTimes() {
        let viewModel = makeViewModel(groupName: "Test", facets: [.author, .title])

        // Rapidly change sort multiple times — final value must be the last assignment
        viewModel.activeSort = .title
        viewModel.activeSort = .author
        viewModel.activeSort = .title
        let finalSort: Facet = .author
        viewModel.activeSort = finalSort

        // Verify the last assignment wins and other state is unaffected
        XCTAssertEqual(viewModel.activeSort, finalSort)
        XCTAssertEqual(viewModel.facets.count, 2, "Rapid sort changes must not mutate the facets array")
        XCTAssertEqual(viewModel.groupName, "Test", "Rapid sort changes must not mutate groupName")
    }

    func testSettingSameSortValue() {
        let viewModel = makeViewModel(groupName: "Test", facets: [.author, .title])

        let expectation = XCTestExpectation(description: "activeSort should publish")
        expectation.expectedFulfillmentCount = 1

        var receivedValue: Facet?
        viewModel.$activeSort
            .dropFirst()
            .sink { value in
                receivedValue = value
                expectation.fulfill()
            }
            .store(in: &cancellables)

        // Setting same value should still publish
        viewModel.activeSort = .title

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(receivedValue, .title, "Published value must match the assigned value")
    }

    func testEmptyGroupName() {
        let viewModel = makeViewModel(groupName: "", facets: [.author, .title])

        XCTAssertEqual(viewModel.groupName, "")
        XCTAssertEqual(viewModel.facets.count, 2)
    }

    func testGroupNameWithSpecialCharacters() {
        let groupName = "My Books 📚 & More!"
        let viewModel = makeViewModel(groupName: groupName, facets: [.author, .title])

        XCTAssertEqual(viewModel.groupName, groupName)
        XCTAssertFalse(viewModel.groupName.isEmpty, "Group name with special characters must not be empty")
        XCTAssertEqual(viewModel.groupName.count, groupName.count,
                       "Group name with emoji/special chars must preserve all Unicode grapheme clusters")
    }

    func testUpdatingFacetsDoesNotChangeActiveSort() {
        let viewModel = makeViewModel(groupName: "Test", facets: [.author, .title])
        viewModel.activeSort = .title

        // Update facets but keep same values
        viewModel.facets = [.author, .title]

        XCTAssertEqual(viewModel.activeSort, .title)
        XCTAssertEqual(viewModel.facets.count, 2, "Facets array must be updated")
        XCTAssertNotEqual(viewModel.activeSort, .author,
                          "Assigning a new facets array must not revert activeSort to the first facet")
    }

    // MARK: - Publisher Subscription Tests

    func testMultipleSubscribersToActiveSort() {
        let viewModel = makeViewModel(groupName: "Test", facets: [.author, .title])

        let exp1 = XCTestExpectation(description: "First subscriber")
        let exp2 = XCTestExpectation(description: "Second subscriber")

        var received1: Facet?
        var received2: Facet?

        viewModel.$activeSort
            .dropFirst()
            .sink { value in received1 = value; exp1.fulfill() }
            .store(in: &cancellables)

        viewModel.$activeSort
            .dropFirst()
            .sink { value in received2 = value; exp2.fulfill() }
            .store(in: &cancellables)

        viewModel.activeSort = .title

        wait(for: [exp1, exp2], timeout: 1.0)
        XCTAssertEqual(received1, .title, "First subscriber must receive the updated sort value")
        XCTAssertEqual(received2, .title, "Second subscriber must receive the same updated sort value")
    }
}
