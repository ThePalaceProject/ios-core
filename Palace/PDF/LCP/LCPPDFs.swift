//
//  LCPPDFs.swift
//  Palace
//
//  Static predicates that decide which PDF pipeline a book belongs to.
//

#if LCP

import Foundation
import PalaceCatalog
import PalaceBookModel

/// LCP PDF detection helper.
@objc class LCPPDFs: NSObject {

    private static let expectedAcquisitionType = "application/vnd.readium.lcp.license.v1.0+json"

    /// `true` when the book is an LCP-protected PDF that should be routed
    /// through the Readium PDF pipeline rather than PDFKit.
    ///
    /// Legacy predicate: matches only the `/loans/` XML feed shape where
    /// the LCP MIME is the top-level `defaultAcquisition.type`. Prefer
    /// `hasLCPAcquisition(_:)` for new call sites — it also catches the
    /// Marketplace `/groups/` JSON feed shape where the LCP MIME is
    /// nested inside `indirectAcquisitions`.
    @objc static func canOpenBook(_ book: TPPBook) -> Bool {
        guard let defaultAcquisition = book.defaultAcquisition else { return false }
        return book.defaultBookContentType == .pdf && defaultAcquisition.type == expectedAcquisitionType
    }

    /// Returns `true` iff `book` is an LCP-protected PDF, regardless of which
    /// OPDS feed shape Marketplace happened to populate it from.
    ///
    /// Walks the full set of `book.acquisitions` (not just `defaultAcquisition`)
    /// and recurses into each one's `indirectAcquisitions` chain, so all three
    /// real-world shapes match:
    ///
    /// - `/loans/` XML shape: LCP license MIME at top of `defaultAcquisition.type`
    ///   — matches at the outer loop, first iteration.
    /// - `/groups/` JSON shape (Marketplace): top-level type is
    ///   `application/opds-publication+json` with the LCP license nested in
    ///   `indirectAcquisitions` — matches via recursive walk.
    /// - OPDS-Catalog wrapping shape: multiple top-level acquisitions with the
    ///   LCP license MIME as a sibling of the first (PP-4454).
    ///
    /// Mirrors `LCPAudiobooks.hasLCPAcquisition` (PP-4407). The
    /// `defaultBookContentType == .pdf` clause keeps LCP EPUBs and audiobooks
    /// from matching.
    @objc static func hasLCPAcquisition(_ book: TPPBook) -> Bool {
        guard book.defaultBookContentType == .pdf else { return false }
        for acquisition in book.acquisitions {
            if acquisition.type == expectedAcquisitionType {
                return true
            }
            if indirectChainContainsLCP(acquisition.indirectAcquisitions) {
                return true
            }
        }
        return false
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

#endif
