//
//  LCPPDFs.swift
//  Palace
//
//  Post-migration shell. Historically this file wrapped a
//  zip→extract→decrypt pipeline for LCP-protected PDFs. With the move
//  to Readium's PDFNavigator (which streams decrypted pages on demand
//  via the shared GCDHTTPServer), the archive-extraction and
//  byte-range-decryption machinery is obsolete.
//
//  All that remains is a single static predicate used by
//  `MyBooksDownloadCenter.pathExtension(for:)`, `BookService.presentPDF`,
//  and `BookCellModel.didSelectRead` to decide which PDF pipeline a
//  book belongs to.
//

#if LCP

import Foundation

/// LCP PDF detection helper.
@objc class LCPPDFs: NSObject {

    private static let expectedAcquisitionType = "application/vnd.readium.lcp.license.v1.0+json"

    /// `true` when the book is an LCP-protected PDF that should be routed
    /// through the Readium PDF pipeline rather than PDFKit.
    @objc static func canOpenBook(_ book: TPPBook) -> Bool {
        guard let defaultAcquisition = book.defaultAcquisition else { return false }
        return book.defaultBookContentType == .pdf && defaultAcquisition.type == expectedAcquisitionType
    }
}

#endif
