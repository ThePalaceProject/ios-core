//
//  TPPPDFReaderView.swift
//  Palace
//
//  Created by Vladimir Fedorov on 14.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI
import PalaceUIKit

struct TPPPDFReaderView: View {

    typealias DisplayStrings = Strings.TPPLastReadPositionSynchronizer

    @EnvironmentObject var metadata: TPPPDFDocumentMetadata
    @State private var readerMode: TPPPDFReaderMode = .reader
    @State private var shouldRequestPageSync = false
    private var isShowingSearch: Bool {
        readerMode == .search
    }

    /// Pure seam (PP-4748): resolves the reader mode after the search sheet's
    /// `isPresented` flag changes. The previous `.constant(...)` binding could
    /// not write back on an interactive (swipe-down) dismiss, stranding
    /// `readerMode` in `.search` so the search sheet could never be re-opened.
    /// Dismissing the search sheet returns to `.reader`.
    static func searchSheetReaderMode(current: TPPPDFReaderMode, isPresented: Bool) -> TPPPDFReaderMode {
        if !isPresented && current == .search {
            return .reader
        }
        return current
    }

    private var searchSheetBinding: Binding<Bool> {
        Binding(
            get: { isShowingSearch },
            set: { readerMode = Self.searchSheetReaderMode(current: readerMode, isPresented: $0) }
        )
    }

    let document: TPPPDFDocument

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
                              secondaryButton: .cancel(Text(DisplayStrings.stay), action: metadata.dismissRemotePageSync)
                        )
                    }

                TPPPDFPreviewGrid(document: document, pageIndices: nil, isVisible: readerMode == .previews, done: done)
                    .visible(when: readerMode == .previews)
                bookmarkView
                    .visible(when: readerMode == .bookmarks)
                TPPPDFTOCView(document: document, done: done)
                    .visible(when: readerMode == .toc)
            }
            .sheet(isPresented: searchSheetBinding) {
                TPPPDFSearchView(document: document, done: done)
                    .environmentObject(metadata)
            }
        }
    }

    @ViewBuilder
    /// Document renderer
    var documentView: some View {
        if let renderable = document.document {
            TPPPDFView(document: renderable)
        } else {
            unableToLoadView
        }
    }

    @ViewBuilder
    var bookmarkView: some View {
        if !metadata.bookmarks.isEmpty {
            TPPPDFPreviewGrid(document: document, pageIndices: metadata.bookmarks, isVisible: readerMode == .bookmarks, done: done)
                .visible(when: readerMode == .bookmarks)
        } else {
            Text(NSLocalizedString("There are no bookmarks for this book.", comment: ""))
                .palaceFont(.body)
        }
    }

    @ViewBuilder
    var unableToLoadView: some View {
        Text("Unable to load PDF file")
            .palaceFont(.body)
    }

    /// Done picking a page
    func done() {
        readerMode = .reader
    }

    /// Present navigation alert. Delegates the prompt-gating decision
    /// to `TPPPDFDocumentMetadata.shouldPromptRemotePageSync()` which
    /// also accounts for prior Stay decisions on the same remote-page
    /// value — so a fresh open of a book the user already declined
    /// for doesn't re-nag until the server position actually advances.
    func showRemotePositionAlert(_ value: Published<Int?>.Publisher.Output) {
        if metadata.shouldPromptRemotePageSync() {
            shouldRequestPageSync = true
        }
    }
}
