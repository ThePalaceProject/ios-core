//
//  ReadiumPDFReaderView.swift
//  Palace
//
//  SwiftUI host for the Readium-backed PDF reader. Mirrors the shape of
//  `TPPPDFReaderView` (which handles plain-PDF PDFKit rendering) so the
//  navigation chrome — back/TOC/previews/bookmarks/search picker — and
//  side panels stay the same across both PDF pipelines.
//
//  The actual page rendering for LCP PDFs is owned by the embedded
//  `ReadiumPDFContainer` (Readium's `PDFNavigatorViewController` under
//  the hood, streaming decrypted pages on demand via the shared
//  `GCDHTTPServer`). The side panels — `TPPPDFTOCView`,
//  `TPPPDFPreviewGrid`, bookmark view — see a publication-backed
//  `TPPPDFDocument` shim that proxies their TOC/pageCount/label calls
//  to Readium without forking their UI.
//

import SwiftUI
import ReadiumShared
import PalaceUIKit
import PalaceBookModel

struct ReadiumPDFReaderView: View {

    typealias DisplayStrings = Strings.TPPLastReadPositionSynchronizer

    let publication: Publication
    let book: TPPBook

    @EnvironmentObject var metadata: TPPPDFDocumentMetadata
    @EnvironmentObject var coordinator: NavigationCoordinator
    @State private var readerMode: TPPPDFReaderMode = .reader
    @State private var shouldRequestPageSync = false
    @State private var didMarkFirstPageRendered = false

    /// Publication-backed TPPPDFDocument shim used by the side panels.
    /// Built once at view init from the pre-loaded TOC + page count
    /// snapshot so the side panels stay referentially stable.
    private let document: TPPPDFDocument

    init(publication: Publication, book: TPPBook, tableOfContents: [TPPPDFLocation], pageCount: Int) {
        self.publication = publication
        self.book = book
        self.document = TPPPDFDocument(tableOfContents: tableOfContents, pageCount: pageCount)
    }

    var body: some View {
        TPPPDFNavigation(readerMode: $readerMode) { _ in
            ZStack {
                documentView
                    .onReceive(metadata.$remotePage, perform: showRemotePositionAlert)
                    .visible(when: readerMode == .reader || readerMode == .search)
                    .alert(isPresented: $shouldRequestPageSync) {
                        Alert(title: Text(DisplayStrings.syncReadingPositionAlertTitle),
                              message: Text(DisplayStrings.syncReadingPositionAlertBody),
                              primaryButton: .default(Text(DisplayStrings.move), action: metadata.syncReadingPosition),
                              secondaryButton: .cancel(Text(DisplayStrings.stay))
                        )
                    }

                TPPPDFPreviewGrid(document: document, pageIndices: nil, isVisible: readerMode == .previews, done: done)
                    .visible(when: readerMode == .previews)
                bookmarkView
                    .visible(when: readerMode == .bookmarks)
                TPPPDFTOCView(document: document, done: done)
                    .visible(when: readerMode == .toc)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .onDisappear {
            // Drop the publication AND deregister its HTTP-server
            // endpoint so the LCP content-protection state, GCDHTTPServer
            // handler/transformer entries, and decrypted page caches all
            // release — otherwise back-to-back opens accumulate state and
            // the app OOMs on large LCP textbooks. The TOC + page-count
            // snapshot is preserved across this teardown so re-opens
            // repopulate side panels instantly.
            AppContainer.production().readerService
                .releaseReadiumPDF(forBookIdentifier: book.identifier)
        }
    }

    /// Readium-backed page renderer.
    @ViewBuilder
    private var documentView: some View {
        ReadiumPDFContainer(
            publication: publication,
            book: book,
            initialPageIndex: metadata.currentPage,
            onLocationChange: { locator in
                // First emission means page 1 actually rendered — flip
                // off the pending flag so NavigationHostView removes the
                // ReadiumPDFLoadingView overlay. Publication-landed (~100ms)
                // happens long before this; the user-perceived "blank"
                // window covers the seconds it takes PDFNavigator to walk
                // the LCP cross-ref table on the first page request.
                if !didMarkFirstPageRendered {
                    didMarkFirstPageRendered = true
                    coordinator.markReadiumPDFFirstPageRendered(forBookId: book.identifier)
                    LCPPDFOpenProgress.shared.finish()
                }
                // `Locator.locations.position` is 1-indexed; Palace's
                // metadata is 0-indexed. Keep metadata as-is so TOC and
                // bookmarks keep using the existing page-number contract.
                if let position = locator.locations.position {
                    metadata.currentPage = max(0, position - 1)
                }
            }
        )
    }

    @ViewBuilder
    private var bookmarkView: some View {
        if !metadata.bookmarks.isEmpty {
            TPPPDFPreviewGrid(document: document, pageIndices: metadata.bookmarks, isVisible: readerMode == .bookmarks, done: done)
                .visible(when: readerMode == .bookmarks)
        } else {
            Text(NSLocalizedString("There are no bookmarks for this book.", comment: ""))
                .palaceFont(.body)
        }
    }

    /// Done picking a page — return to the reader view.
    private func done() {
        readerMode = .reader
    }

    /// Present navigation alert when the remote reading position differs
    /// from the local one.
    private func showRemotePositionAlert(_ value: Published<Int?>.Publisher.Output) {
        if let value = value, metadata.currentPage != value {
            shouldRequestPageSync = true
        }
    }
}
