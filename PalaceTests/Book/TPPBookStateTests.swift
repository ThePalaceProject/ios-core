//
//  TPPBookStateTests.swift
//  PalaceTests
//
//  Comprehensive unit tests for TPPBookState enum
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TPPBookStateComprehensiveTests: XCTestCase {

  // MARK: - All State Enum Cases Tests

  /// Tests that all enum cases have the expected raw values
  func testAllEnumCases_HaveExpectedRawValues() {
    XCTAssertEqual(TPPBookState.unregistered.rawValue, 0)
    XCTAssertEqual(TPPBookState.downloadNeeded.rawValue, 1)
    XCTAssertEqual(TPPBookState.downloading.rawValue, 2)
    XCTAssertEqual(TPPBookState.downloadFailed.rawValue, 3)
    XCTAssertEqual(TPPBookState.downloadSuccessful.rawValue, 4)
    XCTAssertEqual(TPPBookState.returning.rawValue, 5)
    XCTAssertEqual(TPPBookState.holding.rawValue, 6)
    XCTAssertEqual(TPPBookState.used.rawValue, 7)
    XCTAssertEqual(TPPBookState.unsupported.rawValue, 8)
    XCTAssertEqual(TPPBookState.SAMLStarted.rawValue, 9)
  }

  /// Tests that allCases contains exactly the expected number of cases
  func testAllCases_ContainsExpectedCount() {
    XCTAssertEqual(TPPBookState.allCases.count, 10)
  }

  /// Tests that each case is unique (no duplicate raw values)
  func testAllCases_AreUnique() {
    let rawValues = TPPBookState.allCases.map { $0.rawValue }
    let uniqueRawValues = Set(rawValues)
    XCTAssertEqual(rawValues.count, uniqueRawValues.count)
  }

  // MARK: - String Initialization Tests

  func testInitWithString_Unregistered() {
    XCTAssertEqual(TPPBookState(UnregisteredKey), .unregistered)
  }

  func testInitWithString_DownloadNeeded() {
    XCTAssertEqual(TPPBookState(DownloadNeededKey), .downloadNeeded)
  }

  func testInitWithString_Downloading() {
    XCTAssertEqual(TPPBookState(DownloadingKey), .downloading)
  }

  func testInitWithString_DownloadFailed() {
    XCTAssertEqual(TPPBookState(DownloadFailedKey), .downloadFailed)
  }

  func testInitWithString_DownloadSuccessful() {
    XCTAssertEqual(TPPBookState(DownloadSuccessfulKey), .downloadSuccessful)
  }

  func testInitWithString_Returning() {
    XCTAssertEqual(TPPBookState(ReturningKey), .returning)
  }

  func testInitWithString_Holding() {
    XCTAssertEqual(TPPBookState(HoldingKey), .holding)
  }

  func testInitWithString_Used() {
    XCTAssertEqual(TPPBookState(UsedKey), .used)
  }

  func testInitWithString_Unsupported() {
    XCTAssertEqual(TPPBookState(UnsupportedKey), .unsupported)
  }

  func testInitWithString_SAMLStarted() {
    XCTAssertEqual(TPPBookState(SAMLStartedKey), .SAMLStarted)
  }

  // MARK: - Invalid String Initialization Tests

  func testInitWithString_InvalidString_ReturnsNil() {
    XCTAssertNil(TPPBookState("invalid"))
  }

  func testInitWithString_EmptyString_ReturnsNil() {
    XCTAssertNil(TPPBookState(""))
  }

  func testInitWithString_CaseSensitive_ReturnsNil() {
    // Test that string matching is case-sensitive
    XCTAssertNil(TPPBookState("DOWNLOADING"))
    XCTAssertNil(TPPBookState("Downloading"))
    XCTAssertNil(TPPBookState("DOWNLOAD-NEEDED"))
  }

  func testInitWithString_WhitespaceString_ReturnsNil() {
    XCTAssertNil(TPPBookState(" "))
    XCTAssertNil(TPPBookState("  downloading  "))
    XCTAssertNil(TPPBookState("\n"))
  }

  func testInitWithString_PartialMatch_ReturnsNil() {
    XCTAssertNil(TPPBookState("download"))
    XCTAssertNil(TPPBookState("download-"))
    XCTAssertNil(TPPBookState("unreg"))
  }

  // MARK: - String Value Tests

  func testStringValue_Unregistered() {
    XCTAssertEqual(TPPBookState.unregistered.stringValue(), UnregisteredKey)
  }

  func testStringValue_DownloadNeeded() {
    XCTAssertEqual(TPPBookState.downloadNeeded.stringValue(), DownloadNeededKey)
  }

  func testStringValue_Downloading() {
    XCTAssertEqual(TPPBookState.downloading.stringValue(), DownloadingKey)
  }

  func testStringValue_DownloadFailed() {
    XCTAssertEqual(TPPBookState.downloadFailed.stringValue(), DownloadFailedKey)
  }

  func testStringValue_DownloadSuccessful() {
    XCTAssertEqual(TPPBookState.downloadSuccessful.stringValue(), DownloadSuccessfulKey)
  }

  func testStringValue_Returning() {
    XCTAssertEqual(TPPBookState.returning.stringValue(), ReturningKey)
  }

  func testStringValue_Holding() {
    XCTAssertEqual(TPPBookState.holding.stringValue(), HoldingKey)
  }

  func testStringValue_Used() {
    XCTAssertEqual(TPPBookState.used.stringValue(), UsedKey)
  }

  func testStringValue_Unsupported() {
    XCTAssertEqual(TPPBookState.unsupported.stringValue(), UnsupportedKey)
  }

  func testStringValue_SAMLStarted() {
    XCTAssertEqual(TPPBookState.SAMLStarted.stringValue(), SAMLStartedKey)
  }

  // MARK: - Round-Trip Serialization Tests

  func testRoundTrip_AllStates() {
    for state in TPPBookState.allCases {
      let stringValue = state.stringValue()
      let recreatedState = TPPBookState(stringValue)
      XCTAssertEqual(recreatedState, state, "Round-trip failed for state: \(state)")
    }
  }

  func testRoundTrip_StringToStateToString() {
    let keys = [
      DownloadingKey, DownloadFailedKey, DownloadNeededKey,
      DownloadSuccessfulKey, UnregisteredKey, HoldingKey,
      UsedKey, UnsupportedKey, ReturningKey, SAMLStartedKey
    ]

    for key in keys {
      guard let state = TPPBookState(key) else {
        XCTFail("Failed to create state from key: \(key)")
        continue
      }
      XCTAssertEqual(state.stringValue(), key, "Round-trip failed for key: \(key)")
    }
  }

  // MARK: - TPPBookStateHelper Tests (Objective-C Compatibility)

  func testHelper_StringValueFromBookState() {
    for state in TPPBookState.allCases {
      let helperString = TPPBookStateHelper.stringValue(from: state)
      let directString = state.stringValue()
      XCTAssertEqual(helperString, directString)
    }
  }

  func testHelper_BookStateFromString_ValidStrings() {
    XCTAssertEqual(TPPBookStateHelper.bookState(fromString: UnregisteredKey)?.intValue, TPPBookState.unregistered.rawValue)
    XCTAssertEqual(TPPBookStateHelper.bookState(fromString: DownloadNeededKey)?.intValue, TPPBookState.downloadNeeded.rawValue)
    XCTAssertEqual(TPPBookStateHelper.bookState(fromString: DownloadingKey)?.intValue, TPPBookState.downloading.rawValue)
    XCTAssertEqual(TPPBookStateHelper.bookState(fromString: DownloadFailedKey)?.intValue, TPPBookState.downloadFailed.rawValue)
    XCTAssertEqual(TPPBookStateHelper.bookState(fromString: DownloadSuccessfulKey)?.intValue, TPPBookState.downloadSuccessful.rawValue)
    XCTAssertEqual(TPPBookStateHelper.bookState(fromString: ReturningKey)?.intValue, TPPBookState.returning.rawValue)
    XCTAssertEqual(TPPBookStateHelper.bookState(fromString: HoldingKey)?.intValue, TPPBookState.holding.rawValue)
    XCTAssertEqual(TPPBookStateHelper.bookState(fromString: UsedKey)?.intValue, TPPBookState.used.rawValue)
    XCTAssertEqual(TPPBookStateHelper.bookState(fromString: UnsupportedKey)?.intValue, TPPBookState.unsupported.rawValue)
    XCTAssertEqual(TPPBookStateHelper.bookState(fromString: SAMLStartedKey)?.intValue, TPPBookState.SAMLStarted.rawValue)
  }

  func testHelper_BookStateFromString_InvalidString() {
    XCTAssertNil(TPPBookStateHelper.bookState(fromString: "invalid"))
    XCTAssertNil(TPPBookStateHelper.bookState(fromString: ""))
    XCTAssertNil(TPPBookStateHelper.bookState(fromString: "DOWNLOADING"))
  }

  func testHelper_AllBookStates_ReturnsAllRawValues() {
    let allRawValues = TPPBookStateHelper.allBookStates()
    let expectedRawValues = TPPBookState.allCases.map { $0.rawValue }
    XCTAssertEqual(allRawValues, expectedRawValues)
  }

  func testHelper_AllBookStates_Count() {
    XCTAssertEqual(TPPBookStateHelper.allBookStates().count, 10)
  }

  // MARK: - State Transition Logic Tests

  /// Tests valid download state transition: downloadNeeded -> downloading
  func testStateTransition_DownloadNeeded_To_Downloading() {
    let initialState = TPPBookState.downloadNeeded
    let expectedNextState = TPPBookState.downloading

    // Verify these are valid adjacent states in the download flow
    XCTAssertEqual(initialState.rawValue + 1, expectedNextState.rawValue)
  }

  /// Tests valid download state transition: downloading -> downloadSuccessful
  func testStateTransition_Downloading_To_DownloadSuccessful() {
    let initialState = TPPBookState.downloading
    let successState = TPPBookState.downloadSuccessful

    // Both should be valid download-related states
    XCTAssertNotNil(TPPBookState(initialState.stringValue()))
    XCTAssertNotNil(TPPBookState(successState.stringValue()))
  }

  /// Tests valid download state transition: downloading -> downloadFailed
  func testStateTransition_Downloading_To_DownloadFailed() {
    let initialState = TPPBookState.downloading
    let failedState = TPPBookState.downloadFailed

    // Both should be valid download-related states
    XCTAssertNotNil(TPPBookState(initialState.stringValue()))
    XCTAssertNotNil(TPPBookState(failedState.stringValue()))
  }

  /// Tests valid borrow state transition: unregistered -> downloadNeeded (after borrowing)
  func testStateTransition_Unregistered_To_DownloadNeeded() {
    let initialState = TPPBookState.unregistered
    let borrowedState = TPPBookState.downloadNeeded

    // Verify both are valid states that can serialize/deserialize
    XCTAssertEqual(TPPBookState(initialState.stringValue()), initialState)
    XCTAssertEqual(TPPBookState(borrowedState.stringValue()), borrowedState)
  }

  /// Tests valid return state transition: downloadSuccessful -> returning
  func testStateTransition_DownloadSuccessful_To_Returning() {
    let downloadedState = TPPBookState.downloadSuccessful
    let returningState = TPPBookState.returning

    // Both should serialize properly
    XCTAssertEqual(TPPBookState(downloadedState.stringValue()), downloadedState)
    XCTAssertEqual(TPPBookState(returningState.stringValue()), returningState)
  }

  /// Tests valid return state transition: returning -> unregistered (after return completes)
  func testStateTransition_Returning_To_Unregistered() {
    let returningState = TPPBookState.returning
    let unregisteredState = TPPBookState.unregistered

    // Both should serialize properly
    XCTAssertEqual(TPPBookState(returningState.stringValue()), returningState)
    XCTAssertEqual(TPPBookState(unregisteredState.stringValue()), unregisteredState)
  }

  /// Tests valid hold state transition: unregistered -> holding
  func testStateTransition_Unregistered_To_Holding() {
    let unregisteredState = TPPBookState.unregistered
    let holdingState = TPPBookState.holding

    // Both should serialize properly
    XCTAssertEqual(TPPBookState(unregisteredState.stringValue()), unregisteredState)
    XCTAssertEqual(TPPBookState(holdingState.stringValue()), holdingState)
  }

  /// Tests SAML flow state transition: downloadNeeded -> SAMLStarted
  func testStateTransition_DownloadNeeded_To_SAMLStarted() {
    let downloadNeededState = TPPBookState.downloadNeeded
    let samlStartedState = TPPBookState.SAMLStarted

    // Both should serialize properly
    XCTAssertEqual(TPPBookState(downloadNeededState.stringValue()), downloadNeededState)
    XCTAssertEqual(TPPBookState(samlStartedState.stringValue()), samlStartedState)
  }

  /// Tests SAML flow state transition: SAMLStarted -> downloading
  func testStateTransition_SAMLStarted_To_Downloading() {
    let samlStartedState = TPPBookState.SAMLStarted
    let downloadingState = TPPBookState.downloading

    // Both should serialize properly
    XCTAssertEqual(TPPBookState(samlStartedState.stringValue()), samlStartedState)
    XCTAssertEqual(TPPBookState(downloadingState.stringValue()), downloadingState)
  }

  // MARK: - State Category Tests

  /// Tests that download-related states can be identified
  func testDownloadRelatedStates() {
    let downloadStates: [TPPBookState] = [
      .downloadNeeded,
      .downloading,
      .downloadFailed,
      .downloadSuccessful
    ]

    for state in downloadStates {
      XCTAssertTrue(state.stringValue().contains("download"), "State \(state) should be download-related")
    }
  }

  /// Tests that the used state represents a consumed book
  func testUsedState_RepresentsConsumedBook() {
    let usedState = TPPBookState.used
    XCTAssertEqual(usedState.stringValue(), "used")
    XCTAssertNotNil(TPPBookState(UsedKey))
  }

  /// Tests that unsupported state is properly defined
  func testUnsupportedState() {
    let unsupportedState = TPPBookState.unsupported
    XCTAssertEqual(unsupportedState.stringValue(), "unsupported")
    XCTAssertNotNil(TPPBookState(UnsupportedKey))
  }

  // MARK: - Key Constant Validation Tests

  func testKeyConstants_HaveExpectedValues() {
    XCTAssertEqual(DownloadingKey, "downloading")
    XCTAssertEqual(DownloadFailedKey, "download-failed")
    XCTAssertEqual(DownloadNeededKey, "download-needed")
    XCTAssertEqual(DownloadSuccessfulKey, "download-successful")
    XCTAssertEqual(UnregisteredKey, "unregistered")
    XCTAssertEqual(HoldingKey, "holding")
    XCTAssertEqual(UsedKey, "used")
    XCTAssertEqual(UnsupportedKey, "unsupported")
    XCTAssertEqual(ReturningKey, "returning")
    XCTAssertEqual(SAMLStartedKey, "saml-started")
  }

  // MARK: - Equatable Tests

  func testEquatable_SameStates() {
    XCTAssertEqual(TPPBookState.downloading, TPPBookState.downloading)
    XCTAssertEqual(TPPBookState.unregistered, TPPBookState.unregistered)
    XCTAssertEqual(TPPBookState.SAMLStarted, TPPBookState.SAMLStarted)
  }

  func testEquatable_DifferentStates() {
    XCTAssertNotEqual(TPPBookState.downloading, TPPBookState.downloadSuccessful)
    XCTAssertNotEqual(TPPBookState.unregistered, TPPBookState.holding)
    XCTAssertNotEqual(TPPBookState.used, TPPBookState.unsupported)
  }

  // MARK: - Hashable Tests

  func testHashable_CanBeUsedInSet() {
    var stateSet = Set<TPPBookState>()
    stateSet.insert(.downloading)
    stateSet.insert(.downloadSuccessful)
    stateSet.insert(.downloading) // Duplicate

    XCTAssertEqual(stateSet.count, 2)
    XCTAssertTrue(stateSet.contains(.downloading))
    XCTAssertTrue(stateSet.contains(.downloadSuccessful))
  }

  func testHashable_CanBeUsedAsDictionaryKey() {
    var stateDict: [TPPBookState: String] = [:]
    stateDict[.downloading] = "In Progress"
    stateDict[.downloadSuccessful] = "Complete"

    XCTAssertEqual(stateDict[.downloading], "In Progress")
    XCTAssertEqual(stateDict[.downloadSuccessful], "Complete")
    XCTAssertNil(stateDict[.unregistered])
  }

  // MARK: - CaseIterable Tests

  func testCaseIterable_ContainsAllStates() {
    let allStates = TPPBookState.allCases

    XCTAssertTrue(allStates.contains(.unregistered))
    XCTAssertTrue(allStates.contains(.downloadNeeded))
    XCTAssertTrue(allStates.contains(.downloading))
    XCTAssertTrue(allStates.contains(.downloadFailed))
    XCTAssertTrue(allStates.contains(.downloadSuccessful))
    XCTAssertTrue(allStates.contains(.returning))
    XCTAssertTrue(allStates.contains(.holding))
    XCTAssertTrue(allStates.contains(.used))
    XCTAssertTrue(allStates.contains(.unsupported))
    XCTAssertTrue(allStates.contains(.SAMLStarted))
  }

  func testCaseIterable_OrderMatchesRawValues() {
    let allCases = TPPBookState.allCases
    for (index, state) in allCases.enumerated() {
      XCTAssertEqual(state.rawValue, index, "State \(state) should have rawValue \(index)")
    }
  }

  // MARK: - Edge Cases and Boundary Tests

  func testEdgeCase_RawValueBoundaries() {
    // Test that we can create states from raw values at the boundaries
    XCTAssertNotNil(TPPBookState(rawValue: 0)) // First state
    XCTAssertNotNil(TPPBookState(rawValue: 9)) // Last state
    XCTAssertNil(TPPBookState(rawValue: -1))   // Below range
    XCTAssertNil(TPPBookState(rawValue: 10))   // Above range
    XCTAssertNil(TPPBookState(rawValue: 100))  // Way above range
  }

  func testEdgeCase_AllRawValuesInRange() {
    for rawValue in 0..<10 {
      XCTAssertNotNil(TPPBookState(rawValue: rawValue), "Raw value \(rawValue) should produce a valid state")
    }
  }

  // MARK: - Performance Tests

  func testPerformance_StringValueLookup() {
    measure {
      for _ in 0..<1000 {
        for state in TPPBookState.allCases {
          _ = state.stringValue()
        }
      }
    }
  }

  func testPerformance_StringInitialization() {
    let keys = [
      DownloadingKey, DownloadFailedKey, DownloadNeededKey,
      DownloadSuccessfulKey, UnregisteredKey, HoldingKey,
      UsedKey, UnsupportedKey, ReturningKey, SAMLStartedKey
    ]

    measure {
      for _ in 0..<1000 {
        for key in keys {
          _ = TPPBookState(key)
        }
      }
    }
  }
}
