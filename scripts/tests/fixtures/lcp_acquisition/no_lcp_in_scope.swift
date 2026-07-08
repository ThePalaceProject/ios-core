// Fixture: a download-path predicate that uses `defaultAcquisition` but
// has nothing to do with LCP — no LCP MIME literal, no
// `expectedAcquisitionType`, no `ContentTypeReadiumLCP`. The detector
// must NOT flag this; it's a false-positive immunity check.
//
// Modeled after `Palace/MyBooks/BorrowOperation.swift:201` shape.
//
// Expected: detector does NOT flag this function.

import Foundation

final class BorrowOperationFixture {
    // no-superpartner: detector fixture, exercised via test_check_lcp_acquisition_recursive.py
    func availabilityWindow(for book: TPPBook) -> AvailabilityWindow? {
        guard let availability = book.defaultAcquisition?.availability else {
            return nil
        }
        return AvailabilityWindow(from: availability)
    }

    // A second helper that uses defaultAcquisition for URL routing. Still
    // no LCP context.
    // no-superpartner: detector fixture, exercised via test_check_lcp_acquisition_recursive.py
    func fetchURL(for book: TPPBook) -> URL? {
        guard let acquisitionURL = book.defaultAcquisition?.hrefURL else {
            return nil
        }
        return acquisitionURL
    }
}
