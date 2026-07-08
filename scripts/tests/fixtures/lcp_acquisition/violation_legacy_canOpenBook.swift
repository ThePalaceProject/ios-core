// Fixture: legacy `canOpenBook(_:)` shape that inspects only
// `defaultAcquisition.type`. This is the exact bug class from
// PP-4407 (audiobooks) and PP-4454 (LCP PDFs).
//
// Expected: detector flags this function.

import Foundation

@objc class LCPAudiobooksFixture: NSObject {
    private static let expectedAcquisitionType = "application/vnd.readium.lcp.license.v1.0+json"

    // no-superpartner: detector fixture, exercised via test_check_lcp_acquisition_recursive.py
    @objc static func canOpenBook(_ book: TPPBook) -> Bool {
        guard let defaultAcquisition = book.defaultAcquisition else { return false }
        return book.defaultBookContentType == .audiobook && defaultAcquisition.type == expectedAcquisitionType
    }
}
