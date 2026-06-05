// Fixture: predicate inspects defaultAcquisition + recurses through
// indirectAcquisitions. Clean — matches the canonical PR #958 / #1008
// recursive walk shape.
//
// Expected: detector does NOT flag this function.

import Foundation

@objc class LCPAudiobooksRecursiveFixture: NSObject {
    private static let expectedAcquisitionType = "application/vnd.readium.lcp.license.v1.0+json"

    // no-superpartner: detector fixture, exercised via test_check_lcp_acquisition_recursive.py
    @objc static func hasLCPAcquisition(_ book: TPPBook) -> Bool {
        guard book.defaultBookContentType == .audiobook,
              let acquisition = book.defaultAcquisition else {
            return false
        }
        if acquisition.type == expectedAcquisitionType {
            return true
        }
        return indirectChainContainsLCP(acquisition.indirectAcquisitions)
    }

    private static func indirectChainContainsLCP(_ chain: [TPPOPDSIndirectAcquisition]) -> Bool {
        for node in chain {
            if node.type == expectedAcquisitionType {
                return true
            }
            if indirectChainContainsLCP(node.indirectAcquisitions) {
                return true
            }
        }
        return false
    }
}
