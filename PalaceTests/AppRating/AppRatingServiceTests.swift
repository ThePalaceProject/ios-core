//
//  AppRatingServiceTests.swift
//  PalaceTests
//
//  Tests for AppRatingService (Epic PP-4086, PR 1): recording delegation,
//  crash-free probe wiring, injected clock, and eligibility gating (master
//  switch + policy + config).
//

import XCTest
import PalacePreferences
@testable import Palace

@MainActor
final class AppRatingServiceTests: XCTestCase {

  private var suiteName: String!
  private var defaults: UserDefaults!
  private var settings: TPPSettings!
  private let now = Date(timeIntervalSince1970: 1_000_000_000)

  override func setUp() {
    super.setUp()
    suiteName = "AppRatingServiceTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    settings = TPPSettings(defaults: defaults)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    settings = nil
    defaults = nil
    suiteName = nil
    super.tearDown()
  }

  private func makeService(
    config: RatingConfig = .fallback,
    promptEnabled: Bool = true,
    crashFree: Bool = true
  ) -> AppRatingService {
    AppRatingService(
      tracker: RatingEngagementTracker(settings: settings),
      configProvider: { config },
      promptEnabledProvider: { promptEnabled },
      crashFreeProbe: { crashFree },
      now: { self.now }
    )
  }

  /// Writes a fully-eligible engagement state directly into settings.
  private func seedEligibleState() {
    settings.appRatingSessionCount = 5
    settings.appRatingBooksCompleted = 1
    settings.appRatingPromptDisplayCount = 0
    settings.appRatingOptedOut = false
    settings.appRatingCrashFreeLastSession = true
    settings.appRatingLastPromptDate = nil
  }

  // MARK: - Recording delegation

  func testRecordSession_incrementsCountAndStoresCrashProbeResult() {
    let service = makeService(crashFree: false)
    service.recordSession()
    XCTAssertEqual(settings.appRatingSessionCount, 1)
    XCTAssertFalse(settings.appRatingCrashFreeLastSession, "should persist the crash-probe result")
  }

  func testRecordBookCompleted_incrementsBooksCompleted() {
    let service = makeService()
    service.recordBookCompleted()
    XCTAssertEqual(settings.appRatingBooksCompleted, 1)
  }

  func testRecordPromptShown_usesInjectedClockAndIncrementsDisplayCount() {
    let service = makeService()
    service.recordPromptShown()
    XCTAssertEqual(settings.appRatingLastPromptDate, now, "should stamp the injected clock time")
    XCTAssertEqual(settings.appRatingPromptDisplayCount, 1)
  }

  func testRecordDismissal_incrementsDismissalCount() {
    let service = makeService()
    service.recordDismissal()
    XCTAssertEqual(settings.appRatingDismissalCount, 1)
  }

  func testRecordOptOut_setsOptedOut() {
    let service = makeService()
    service.recordOptOut()
    XCTAssertTrue(settings.appRatingOptedOut)
  }

  // MARK: - Eligibility gating

  func testIsEligible_whenEligibleAndSwitchOn_returnsTrue() {
    seedEligibleState()
    let service = makeService(promptEnabled: true)
    XCTAssertTrue(service.isEligible(for: .bookCompleted))
    XCTAssertTrue(service.isEligible(for: .borrowSucceeded))
  }

  func testIsEligible_whenMasterSwitchOff_returnsFalseEvenIfOtherwiseEligible() {
    seedEligibleState()
    let service = makeService(promptEnabled: false)
    XCTAssertFalse(service.isEligible(for: .bookCompleted))
  }

  func testIsEligible_whenPolicyFails_returnsFalse() {
    seedEligibleState()
    settings.appRatingOptedOut = true // policy-level disqualifier
    let service = makeService(promptEnabled: true)
    XCTAssertFalse(service.isEligible(for: .bookCompleted))
  }

  func testIsEligible_honorsInjectedConfigThresholds() {
    seedEligibleState() // sessionCount 5
    let stricter = RatingConfig(minSessions: 10, minBooksCompleted: 1, cooldownDays: 90, lifetimePromptCap: 3)
    let service = makeService(config: stricter, promptEnabled: true)
    XCTAssertFalse(service.isEligible(for: .bookCompleted), "stricter session floor should disqualify")
  }
}
