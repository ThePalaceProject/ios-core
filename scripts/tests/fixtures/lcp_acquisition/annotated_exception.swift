// Fixture: legacy shape preserved deliberately for Obj-C source compat,
// annotated with the escape hatch. The recursive `hasLCPAcquisition` is
// the new call site; this `canOpenBook` is kept for one release for
// downstream Obj-C callers.
//
// Expected: detector does NOT flag this function (annotation honored).

import Foundation

@objc class LCPAudiobooksAnnotatedFixture: NSObject {
    private static let expectedAcquisitionType = "application/vnd.readium.lcp.license.v1.0+json"

    // no-lcp-recursive: legacy Obj-C source-compat shim, callers migrate to
    // `hasLCPAcquisition(_:)` next release; safe because no production path
    // routes through this function for Marketplace feed shapes.
    // no-superpartner: detector fixture, exercised via test_check_lcp_acquisition_recursive.py
    @objc static func canOpenBook(_ book: TPPBook) -> Bool {
        guard let defaultAcquisition = book.defaultAcquisition else { return false }
        return book.defaultBookContentType == .audiobook && defaultAcquisition.type == expectedAcquisitionType
    }
}
