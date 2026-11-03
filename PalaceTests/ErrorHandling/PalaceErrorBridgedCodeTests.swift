//
//  PalaceErrorBridgedCodeTests.swift
//  PalaceTests
//
//  PalaceError is not CustomNSError, so its bridged NSError code is the case's
//  declaration index. `PalaceError.from` decodes that index and Crashlytics
//  groups by it, so a case inserted mid-enum renumbers every later case.
//

import XCTest
@testable import Palace

final class PalaceErrorBridgedCodeTests: XCTestCase {

    private let samples: [(code: Int, error: PalaceError)] = [
        (0, .network(.unknown)),
        (1, .bookRegistry(.invalidState)),
        (2, .download(.networkFailure)),
        (3, .parsing(.opdsFeedInvalid)),
        (4, .drm(.authenticationFailed)),
        (5, .authentication(.invalidCredentials)),
        (6, .storage(.insufficientSpace)),
        (7, .bookReader(.bookNotAvailable)),
        (8, .audiobook(.playbackError)),
        (9, .holdRequeued(position: 3))
    ]

    private var domain: String { (PalaceError.network(.unknown) as NSError).domain }

    /// Every top-level case keeps the bridged code it shipped with; the PP-5453 case is appended.
    func testBridgedCode_EveryTopLevelCase_KeepsItsIndex() {
        for sample in samples {
            XCTAssertEqual((sample.error as NSError).code, sample.code, "\(sample.error)")
        }
    }

    /// A bridged code 0-8 decodes back to the same top-level case.
    func testFrom_PalaceDomainCodes0Through8_RoundTripToTheSameCase() {
        for code in 0...8 {
            let decoded = PalaceError.from(NSError(domain: domain, code: code))
            XCTAssertEqual((decoded as NSError).code, code, "code \(code) decoded as \(decoded)")
        }
    }

    /// Code 9 carries no position once bridged, so it decodes to the general hold error.
    func testFrom_PalaceDomainCode9_DecodesToHoldCopyUnavailable() {
        let decoded = PalaceError.from(NSError(domain: domain, code: 9))

        guard case .bookRegistry(.holdCopyUnavailable) = decoded else {
            return XCTFail("expected .holdCopyUnavailable, got \(decoded)")
        }
    }
}
