//
//  BadgesViewModelTests.swift
//  PalaceTests
//
//  Tests for BadgesViewModel badge loading, selection, and notification handling.
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

@MainActor
final class BadgesViewModelTests: XCTestCase {

  private var viewModel: BadgesViewModel!
  private var mockBadgeService: MockBadgeService!
  private var cancellables: Set<AnyCancellable>!

  override func setUp() {
    super.setUp()
    mockBadgeService = MockBadgeService()
    viewModel = BadgesViewModel(badgeService: mockBadgeService)
    cancellables = Set<AnyCancellable>()
  }

  override func tearDown() {
    viewModel = nil
    mockBadgeService = nil
    cancellables = nil
    super.tearDown()
  }

  // MARK: - Test Helpers

  private func makeBadge(
    id: String,
    name: String = "Test Badge",
    tier: BadgeTier = .bronze,
    earnedDate: Date? = nil,
    progress: Double = 0
  ) -> Badge {
    Badge(
      id: id,
      name: name,
      descriptionText: "Description",
      iconName: "star",
      tier: tier,
      earnedDate: earnedDate,
      progress: progress
    )
  }

  // MARK: - Initial State

  func testInitialState_HasEmptyBadgeLists() {
    XCTAssertTrue(viewModel.earnedBadges.isEmpty)
    XCTAssertTrue(viewModel.inProgressBadges.isEmpty)
    XCTAssertTrue(viewModel.lockedBadges.isEmpty)
  }

  func testInitialState_IsNotLoading() {
    XCTAssertFalse(viewModel.isLoading)
  }

  func testInitialState_NoSelectedBadge() {
    XCTAssertNil(viewModel.selectedBadge)
    XCTAssertFalse(viewModel.showBadgeDetail)
  }

  // MARK: - Load

  func testLoad_PopulatesEarnedBadges() async {
    let earned = [makeBadge(id: "1", earnedDate: Date())]
    mockBadgeService.earnedBadgesResult = earned

    await viewModel.load()

    XCTAssertEqual(viewModel.earnedBadges.count, 1)
    XCTAssertEqual(viewModel.earnedBadges.first?.id, "1")
  }

  func testLoad_PopulatesInProgressBadges() async {
    let inProgress = [makeBadge(id: "2", progress: 0.5)]
    mockBadgeService.inProgressBadgesResult = inProgress

    await viewModel.load()

    XCTAssertEqual(viewModel.inProgressBadges.count, 1)
    XCTAssertEqual(viewModel.inProgressBadges.first?.id, "2")
  }

  func testLoad_PopulatesLockedBadges() async {
    let locked = [makeBadge(id: "3", progress: 0)]
    mockBadgeService.lockedBadgesResult = locked

    await viewModel.load()

    XCTAssertEqual(viewModel.lockedBadges.count, 1)
    XCTAssertEqual(viewModel.lockedBadges.first?.id, "3")
  }

  func testLoad_SetsIsLoadingFalseOnCompletion() async {
    await viewModel.load()

    XCTAssertFalse(viewModel.isLoading)
  }

  // MARK: - selectBadge

  func testSelectBadge_SetsSelectedBadge() {
    let badge = makeBadge(id: "selected")

    viewModel.selectBadge(badge)

    XCTAssertEqual(viewModel.selectedBadge?.id, "selected")
    XCTAssertTrue(viewModel.showBadgeDetail)
  }

  // MARK: - totalBadgesCount

  func testTotalBadgesCount_MatchesCatalogCount() {
    XCTAssertEqual(viewModel.totalBadgesCount, BadgeCatalog.all.count)
  }

  // MARK: - progressSummary

  func testProgressSummary_FormatsCorrectly() async {
    let earned = [
      makeBadge(id: "1", earnedDate: Date()),
      makeBadge(id: "2", earnedDate: Date()),
    ]
    mockBadgeService.earnedBadgesResult = earned

    await viewModel.load()

    XCTAssertEqual(viewModel.progressSummary, "2/\(BadgeCatalog.all.count) badges earned")
  }

  func testProgressSummary_ZeroEarned() {
    XCTAssertEqual(viewModel.progressSummary, "0/\(BadgeCatalog.all.count) badges earned")
  }

  // MARK: - Badge Notification Handling

  func testNewBadgeNotification_AddsToBadgeIDs() {
    let badge = makeBadge(id: "new-badge", earnedDate: Date())

    NotificationCenter.default.post(name: .badgeEarned, object: badge)

    // The notification handler runs on main queue
    let expectation = XCTestExpectation(description: "Notification processed")
    DispatchQueue.main.async {
      XCTAssertTrue(self.viewModel.newlyEarnedBadgeIDs.contains("new-badge"))
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)
  }

  func testNewBadgeNotification_TriggersReload() {
    let badge = makeBadge(id: "trigger-reload", earnedDate: Date())
    let earned = [badge]
    mockBadgeService.earnedBadgesResult = earned

    NotificationCenter.default.post(name: .badgeEarned, object: badge)

    let expectation = XCTestExpectation(description: "Reload triggered")
    // Give the async load() call time to run
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      // The load() was called, which sets earnedBadges
      XCTAssertEqual(self.viewModel.earnedBadges.count, 1)
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 2.0)
  }

  // MARK: - Badge Categories Mutually Exclusive

  func testBadgeCategories_AreMutuallyExclusive() async {
    let earned = [makeBadge(id: "e1", earnedDate: Date())]
    let inProgress = [makeBadge(id: "p1", progress: 0.3)]
    let locked = [makeBadge(id: "l1", progress: 0)]
    mockBadgeService.earnedBadgesResult = earned
    mockBadgeService.inProgressBadgesResult = inProgress
    mockBadgeService.lockedBadgesResult = locked

    await viewModel.load()

    let earnedIDs = Set(viewModel.earnedBadges.map(\.id))
    let inProgressIDs = Set(viewModel.inProgressBadges.map(\.id))
    let lockedIDs = Set(viewModel.lockedBadges.map(\.id))

    XCTAssertTrue(earnedIDs.isDisjoint(with: inProgressIDs), "Earned and in-progress should not overlap")
    XCTAssertTrue(earnedIDs.isDisjoint(with: lockedIDs), "Earned and locked should not overlap")
    XCTAssertTrue(inProgressIDs.isDisjoint(with: lockedIDs), "In-progress and locked should not overlap")
  }
}

// MARK: - Mock Badge Service

private final class MockBadgeService: BadgeServiceProtocol, @unchecked Sendable {
  var earnedBadgesResult: [Badge] = []
  var inProgressBadgesResult: [Badge] = []
  var lockedBadgesResult: [Badge] = []
  var evaluateAllResult: [Badge] = []
  var refreshCallCount = 0

  func evaluateAllBadges() async -> [Badge] { evaluateAllResult }
  func earnedBadges() async -> [Badge] { earnedBadgesResult }
  func inProgressBadges() async -> [Badge] { inProgressBadgesResult }
  func lockedBadges() async -> [Badge] { lockedBadgesResult }
  func refresh() async { refreshCallCount += 1 }
}
