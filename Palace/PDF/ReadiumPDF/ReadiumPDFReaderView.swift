//
//  ReadiumPDFReaderView.swift
//  Palace
//
//  SwiftUI host for the Readium-backed PDF reader. Mirrors the shape of
//  TPPPDFReaderView (which handles plain-PDF PDFKit rendering) so the two
//  paths stay symmetric from the navigator's perspective.
//

import SwiftUI
import ReadiumShared
import ReadiumAdapterGCDWebServer

struct ReadiumPDFReaderView: View {
    let publication: Publication
    let book: TPPBook
    let httpServer: GCDHTTPServer

    @EnvironmentObject var metadata: TPPPDFDocumentMetadata

    var body: some View {
        ReadiumPDFContainer(
            publication: publication,
            book: book,
            httpServer: httpServer,
            initialPageIndex: metadata.currentPage,
            onLocationChange: { locator in
                // `Locator.locations.position` is 1-indexed; Palace's metadata
                // is 0-indexed. Keep metadata as-is so TOC/bookmarks keep
                // using the existing page-number contract.
                if let position = locator.locations.position {
                    metadata.currentPage = max(0, position - 1)
                }
            }
        )
        .ignoresSafeArea()
        .navigationBarHidden(false)
    }
}
