@testable import Palace
import XCTest

/// PP-4712 — patron-configurable audiobook skip intervals.
/// Behavior spec for the global skip-interval store: defaults, independence,
/// persistence, and validation against the allowed option set.
final class AudiobookSkipIntervalSettingsTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suiteName: String!

  override func setUp() {
    super.setUp()
    suiteName = "AudiobookSkipIntervalSettingsTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    suiteName = nil
    super.tearDown()
  }

  func testDefaults_whenUnset_areThirtySecondsEachDirection() {
    let settings = AudiobookSkipIntervalSettings(defaults: defaults)
    XCTAssertEqual(settings.forwardInterval, 30)
    XCTAssertEqual(settings.backInterval, 30)
  }

  func testForwardAndBack_areIndependent() {
    let settings = AudiobookSkipIntervalSettings(defaults: defaults)
    settings.forwardInterval = 45
    settings.backInterval = 15
    XCTAssertEqual(settings.forwardInterval, 45)
    XCTAssertEqual(settings.backInterval, 15, "changing forward must not affect back")
  }

  func testChangingOneDirection_doesNotMoveTheOther() {
    let settings = AudiobookSkipIntervalSettings(defaults: defaults)
    settings.backInterval = 60
    XCTAssertEqual(settings.forwardInterval, 30, "back change must leave forward at its default")
    settings.forwardInterval = 15
    XCTAssertEqual(settings.backInterval, 60, "forward change must leave back where it was")
  }

  func testValues_persistAcrossStoreInstances() {
    AudiobookSkipIntervalSettings(defaults: defaults).forwardInterval = 45
    let reopened = AudiobookSkipIntervalSettings(defaults: defaults)
    XCTAssertEqual(reopened.forwardInterval, 45, "must persist across app restarts (new store, same defaults)")
  }

  func testInvalidValue_fallsBackToDefault() {
    let settings = AudiobookSkipIntervalSettings(defaults: defaults)
    settings.forwardInterval = 37 // not in the allowed option set
    XCTAssertEqual(settings.forwardInterval, 30, "an out-of-set value must not be stored; fall back to 30")
  }

  func testAllowedOptions_areTheDefinedSet() {
    XCTAssertEqual(AudiobookSkipIntervalSettings.options, [15, 30, 45, 60])
    XCTAssertTrue(AudiobookSkipIntervalSettings.options.contains(AudiobookSkipIntervalSettings.defaultInterval))
  }
}
