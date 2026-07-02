//
//  AppRatingServiceOverrideTests.swift
//  PalaceTests
//
//  Tests for the PR-2 additions to AppRatingService: the force-eligible
//  override (QA/simdrive) and resetEngagementState.
//

import XCTest
@testable import Palace

@MainActor
final class AppRatingServiceOverrideTests: XCTestCase {

  private var suiteName: String!
  private var defaults: UserDefaults!
  private var settings: TPPSettings!

  override func setUp() {
    super.setUp()
    suiteName = "AppRatingServiceOverrideTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    settings = TPPSettings(defaults: defaults)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    settings = nil; defaults = nil; suiteName = nil
    super.tearDown()
  }

  private func makeService(forceEligible: Bool, promptEnabled: Bool = true) -> AppRatingService {
    AppRatingService(
      tracker: RatingEngagementTracker(settings: settings),
      promptEnabledProvider: { promptEnabled },
      forceEligibleProvider: { forceEligible }
    )
  }

  func testForceEligible_bypassesIneligibleStateAndMasterSwitch() {
    // Fresh install (session 0, no books) AND master switch off — normally
    // doubly ineligible. Force override must still report eligible.
    let service = makeService(forceEligible: true, promptEnabled: false)
    XCTAssertTrue(service.isEligible(for: .bookCompleted))
  }

  func testWithoutForce_ineligibleStateStaysIneligible() {
    let service = makeService(forceEligible: false, promptEnabled: true)
    XCTAssertFalse(service.isEligible(for: .bookCompleted), "fresh install must not be eligible without the override")
  }

  func testResetEngagementState_clearsAllSignals() {
    settings.appRatingSessionCount = 9
    settings.appRatingBooksCompleted = 4
    settings.appRatingPromptDisplayCount = 2
    settings.appRatingDismissalCount = 3
    settings.appRatingOptedOut = true
    settings.appRatingLastPromptDate = Date(timeIntervalSince1970: 1000)
    settings.appRatingCrashFreeLastSession = false

    makeService(forceEligible: false).resetEngagementState()

    XCTAssertEqual(settings.appRatingSessionCount, 0)
    XCTAssertEqual(settings.appRatingBooksCompleted, 0)
    XCTAssertEqual(settings.appRatingPromptDisplayCount, 0)
    XCTAssertEqual(settings.appRatingDismissalCount, 0)
    XCTAssertFalse(settings.appRatingOptedOut)
    XCTAssertNil(settings.appRatingLastPromptDate)
    XCTAssertTrue(settings.appRatingCrashFreeLastSession, "reset restores the crash-free default of true")
  }
}
