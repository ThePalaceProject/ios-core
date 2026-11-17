//
//  TPPPDFDocument.swift
//  Palace
//
//  Created by Vladimir Fedorov on 17.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import PDFKit

/// Search delegate
protocol TPPPDFDocumentDelegate {
    func didMatchString(_ instance: TPPPDFLocation)
}

/// Thin wrapper around a PDFKit `PDFDocument` — a plain PDF, or an LCP PDF
/// already decrypted to disk — carrying a Palace-flavored search delegate and
/// TOC/thumbnail helpers the reader views expect.
@objcMembers class TPPPDFDocument: NSObject {
    let data: Data
    let fileURL: URL?

    var delegate: TPPPDFDocumentDelegate?

    /// Initialize from an in-memory PDF buffer. Kept for the rare sample/preview
    /// caller that already has the bytes and can't expose a URL.
    init(data: Data) {
        self.data = data
        self.fileURL = nil
    }

    /// Initialize from a file on disk — preferred. `PDFDocument(url:)` mmaps
    /// the file and pages in on demand, so opening a 500 MB textbook doesn't
    /// pin the whole buffer in RAM or block the main thread on a synchronous
    /// read.
    init(url: URL) {
        self.data = Data()
        self.fileURL = url
    }

    /// PDFKit document — mmapped from `fileURL` when available, otherwise
    /// parsed from the in-memory `data` buffer.
    lazy var document: PDFKit.PDFDocument? = {
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
            return document?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        }
    }

    /// Number of pages in the PDF document
    var pageCount: Int {
        return document?.pageCount ?? 0
    }

    /// Preview image for a page
    /// - Parameter page: Page number
    /// - Returns: Rendered page image
    ///
    /// `preview` returns a larger image than `thumbnail`
    func preview(for page: Int) -> UIImage? {
        return image(page: page, size: .pdfPreviewSize)
    }

    /// Thumbnail image for a page
    func thumbnail(for page: Int) -> UIImage? {
        return image(page: page, size: .pdfThumbnailSize)
    }

    /// Image for a page
    func image(page: Int, size: CGSize) -> UIImage? {
        document?.page(at: page)?.thumbnail(of: size, for: PDFDisplayBox.mediaBox)
    }

    /// Page size
    func size(page: Int) -> CGSize? {
        return document?.page(at: page)?.bounds(for: PDFDisplayBox.mediaBox).size
    }

    /// Page label
    func label(page: Int) -> String? {
        return document?.page(at: page)?.label
    }

    /// Search the document
    func search(text: String) {
        let searchString = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        document?.delegate = self
        document?.cancelFindString()
        document?.beginFindString(searchString, withOptions: NSString.CompareOptions.caseInsensitive)
    }

    func cancelSearch() {
        document?.cancelFindString()
    }

    /// Table of contents for PDF document
    var tableOfContents: [TPPPDFLocation] {
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
