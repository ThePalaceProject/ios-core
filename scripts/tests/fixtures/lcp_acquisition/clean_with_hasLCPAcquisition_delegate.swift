// Fixture: predicate delegates to the canonical `hasLCPAcquisition(_:)`
// helper. The body still mentions `defaultAcquisition` (for the URL fetch
// downstream) and the LCP MIME (for logging), but the dispatch hinges on
// the recursive helper. Clean — matches the BookFileManager / LCPAdapter
// shape that uses `LCPAudiobooks.hasLCPAcquisition(book)`.
//
// Expected: detector does NOT flag this function.

import Foundation

final class BookFileManagerFixture {
    private static let expectedAcquisitionType = "application/vnd.readium.lcp.license.v1.0+json"

    // no-superpartner: detector fixture, exercised via test_check_lcp_acquisition_recursive.py
    func resolveLocalURL(for book: TPPBook) -> URL? {
        guard book.defaultAcquisition != nil else { return nil }
        if LCPAudiobooks.hasLCPAcquisition(book) {
            return lcpStorePath(for: book)
        }
        return standardStorePath(for: book)
    }
}
