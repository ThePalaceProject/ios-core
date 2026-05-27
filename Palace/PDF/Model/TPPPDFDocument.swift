//
//  TPPPDFDocument.swift
//  Palace
//
//  Created by Vladimir Fedorov on 17.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//
//  Post-migration: this wrapper covers BOTH PDF pipelines:
//  - PDFKit-backed: plain (non-LCP) PDFs initialized via `init(url:)` or
//    `init(data:)`. `document` is a PDFKit `PDFDocument`.
//  - Readium-Publication-backed: LCP-protected PDFs initialized via
//    `init(publication:tableOfContents:pageCount:)`. The Readium
//    `PDFNavigatorViewController` handles page rendering directly via
//    the GCDHTTPServer; this class only proxies the side-bar APIs
//    (table of contents, page count, labels) so `TPPPDFNavigation` +
//    `TPPPDFTOCView` + `TPPPDFPreviewGrid` keep working against LCP PDFs
//    without forking their UI.
//
//  TOC and page count are passed in as snapshots at init time so the
//  consumer-facing API stays synchronous — Readium's `tableOfContents()`
//  and `positions()` are async, but the side panels expect sync getters.
//  The caller (`ReaderService.openPDF`) awaits both before constructing
//  the document.
//

import Foundation
import PDFKit

/// Search delegate
protocol TPPPDFDocumentDelegate {
    func didMatchString(_ instance: TPPPDFLocation)
}

/// Thin wrapper around a PDF source — either a PDFKit `PDFDocument` (open-access
/// path) or a Readium `Publication` (LCP path) — carrying a Palace-flavored
/// search delegate and TOC/thumbnail helpers the reader views expect.
@objcMembers class TPPPDFDocument: NSObject {
    let data: Data
    let fileURL: URL?

    /// Snapshot of TOC + page count for the publication path. `nil` /
    /// `0` for the PDFKit path (which derives them from `document`).
    private let publicationTableOfContents: [TPPPDFLocation]
    private let publicationPageCount: Int

    /// `true` when this document wraps a Readium publication and should
    /// skip PDFKit page access (no `document`, no thumbnails, no
    /// PDFKit-backed search).
    let isPublicationBacked: Bool

    var delegate: TPPPDFDocumentDelegate?

    /// Initialize from an in-memory PDF buffer. Kept for the rare sample/preview
    /// caller that already has the bytes and can't expose a URL.
    init(data: Data) {
        self.data = data
        self.fileURL = nil
        self.publicationTableOfContents = []
        self.publicationPageCount = 0
        self.isPublicationBacked = false
    }

    /// Initialize from a file on disk — preferred. `PDFDocument(url:)` mmaps
    /// the file and pages in on demand, so opening a 500 MB textbook doesn't
    /// pin the whole buffer in RAM or block the main thread on a synchronous
    /// read.
    init(url: URL) {
        self.data = Data()
        self.fileURL = url
        self.publicationTableOfContents = []
        self.publicationPageCount = 0
        self.isPublicationBacked = false
    }

    /// Initialize from a pre-loaded snapshot of a Readium publication's
    /// metadata (LCP path). Page rendering is owned by
    /// `ReadiumPDFViewController`/`PDFNavigatorViewController`; this
    /// wrapper exposes only the side-panel metadata surface — TOC,
    /// pageCount — so the existing `TPPPDFNavigation` chrome keeps
    /// working.
    ///
    /// `tableOfContents` and `pageCount` are accepted as snapshots
    /// (rather than reaching into the publication on demand) because
    /// Readium 3's `tableOfContents()` and `positions()` are async and
    /// the consumer side panels expect synchronous getters.
    init(tableOfContents: [TPPPDFLocation], pageCount: Int) {
        self.data = Data()
        self.fileURL = nil
        self.publicationTableOfContents = tableOfContents
        self.publicationPageCount = pageCount
        self.isPublicationBacked = true
    }

    /// PDFKit document — mmapped from `fileURL` when available, otherwise
    /// parsed from the in-memory `data` buffer. `nil` in publication mode.
    lazy var document: PDFKit.PDFDocument? = {
        if isPublicationBacked { return nil }
        if let fileURL {
            return PDFKit.PDFDocument(url: fileURL)
        }
        return PDFKit.PDFDocument(data: data)
    }()
}

// MARK: - Common properties

extension TPPPDFDocument {

    /// PDF title
    var title: String? {
        get async {
            // PDFKit's `PDFDocument.title` is a sync property, not async,
            // but the legacy API was async-wrapped — preserve that shape.
            if isPublicationBacked { return nil }
            return document?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        }
    }

    /// Number of pages in the PDF document
    var pageCount: Int {
        if isPublicationBacked { return publicationPageCount }
        return document?.pageCount ?? 0
    }

    /// Preview image for a page
    /// - Parameter page: Page number
    /// - Returns: Rendered page image
    ///
    /// `preview` returns a larger image than `thumbnail`
    func preview(for page: Int) -> UIImage? {
        // Page-image rendering in the publication path lives inside Readium's
        // PDFNavigator and isn't exposed as a thumbnail API — the preview
        // grid in publication mode shows page labels only, no thumbnails.
        if isPublicationBacked { return nil }
        return image(page: page, size: .pdfPreviewSize)
    }

    /// Thumbnail image for a page
    func thumbnail(for page: Int) -> UIImage? {
        if isPublicationBacked { return nil }
        return image(page: page, size: .pdfThumbnailSize)
    }

    /// Image for a page
    func image(page: Int, size: CGSize) -> UIImage? {
        document?.page(at: page)?.thumbnail(of: size, for: PDFDisplayBox.mediaBox)
    }

    /// Page size
    func size(page: Int) -> CGSize? {
        // Approximate US-letter at @1x — used by the preview grid to size
        // its cells when no PDFKit page is available. Real bounds would
        // require reading the publication resource bytes; the grid layout
        // looks fine with a constant guess.
        if isPublicationBacked { return CGSize(width: 612, height: 792) }
        return document?.page(at: page)?.bounds(for: PDFDisplayBox.mediaBox).size
    }

    /// Page label
    func label(page: Int) -> String? {
        // Readium's `Locator.locations.position` is 1-indexed and is the
        // closest analog to a PDFKit page label. The caller already falls
        // back to `"\(page + 1)"` so returning nil is safe and consistent
        // with the publication's positions.
        if isPublicationBacked { return nil }
        return document?.page(at: page)?.label
    }

    /// Search the document
    func search(text: String) {
        // TODO: Bridge to `publication.search(query:)` via Readium 3's
        // SearchService in a follow-up. For now publication-mode search
        // is a no-op — the search button is hidden in the navigation
        // chrome when the document is publication-backed.
        if isPublicationBacked { return }
        let searchString = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        document?.delegate = self
        document?.cancelFindString()
        document?.beginFindString(searchString, withOptions: NSString.CompareOptions.caseInsensitive)
    }

    func cancelSearch() {
        if isPublicationBacked { return }
        document?.cancelFindString()
    }

    /// Table of contents for PDF document
    var tableOfContents: [TPPPDFLocation] {
        if isPublicationBacked { return publicationTableOfContents }
        guard let outlineRoot = document?.outlineRoot else {
            return []
        }
        return outlineItems(in: outlineRoot, level: -1)
            .compactMap {
                guard let document = $0.1.document, let page = $0.1.destination?.page else {
                    return nil
                }
                return TPPPDFLocation(
                    title: $0.1.label,
                    subtitle: nil,
                    pageLabel: page.label,
                    pageNumber: document.index(for: page),
                    level: $0.0
                )
            }
    }

    /// Unfolds all outline levels into a flat array with `level` parameter for depth level information
    private func outlineItems(in element: PDFOutline, level: Int = 0) -> [(Int, PDFOutline)] {
        [(level, element)] + (0..<element.numberOfChildren).compactMap { element.child(at: $0) }.flatMap { outlineItems(in: $0, level: level + 1) }
    }
}

extension TPPPDFDocument: PDFDocumentDelegate {
    /// Search delegate for `PDFDocument`
    func didMatchString(_ instance: PDFSelection) {
        guard let extendedSelection = instance.copy() as? PDFSelection else {
            return
        }
        extendedSelection.extendForLineBoundaries()
        let page = instance.pages[0]
        guard let pageNumber = document?.index(for: page) else {
            return
        }
        let location = TPPPDFLocation(title: extendedSelection.string, subtitle: nil, pageLabel: page.label, pageNumber: pageNumber)
        delegate?.didMatchString(location)
    }
}
