//
//  ReadiumPDFReaderView.swift
//  Palace
//
//  SwiftUI host for the Readium-backed PDF reader. Mirrors `TPPPDFReaderView`
//  so the navigation chrome and side panels are shared across both PDF
//  pipelines; the side panels see a publication-backed `TPPPDFDocument` shim.
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
            // Drop the publication and deregister its HTTP-server endpoint so
            // LCP state and decrypted page caches release; back-to-back opens
            // otherwise OOM on large LCP textbooks. The TOC/page-count snapshot
            // is kept for fast re-opens.
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
                // First emission means page 1 rendered, so the loading overlay
                // can go (the publication itself lands much earlier).
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
