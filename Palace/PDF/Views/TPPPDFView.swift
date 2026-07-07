//
//  TPPPDFView.swift
//  Palace
//
//  Created by Vladimir Fedorov on 31.05.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI
@preconcurrency import PDFKit

/// This view shows PDFKit views when PDF is not encrypted
/// PDFKit reading controls (PDFView and PDFThumbnails) are generally faster because of direct data reading,
/// instead of reading blocks of data with data provider.
/// The analog for encrypted documents - `TPPEncryptedPDFView`
struct TPPPDFView: View {

    let document: PDFDocument
    // PP-4297: PalacePDFView subclass so we can gate Copy/Cut/Paste/Look
    // Up/Share on long-press when the book is DRM-protected. The
    // `allowsCopy` flag is applied below in `onAppear`, before any user
    // interaction can reach the view.
    //
    // Today TPPPDFView only renders non-encrypted PDFs — encrypted (LCP)
    // titles go through TPPEncryptedPDFView's bitmap-tile path where text
    // is non-selectable by construction. The gating here is forward-
    // looking for any future PDFKit-rendered DRM-PDF path (e.g. PP-4454
    // Readium-PDF) and a defense against future content where decryption
    // happens upstream of this view.
    let pdfView = PalacePDFView()
    private let pageChangePublisher = NotificationCenter.default.publisher(for: .PDFViewPageChanged)

    @EnvironmentObject var metadata: TPPPDFDocumentMetadata

    @State private var showingDocumentInfo = true
    @State private var isTracking = false
    @State private var documentTitle: String = ""
    @State private var isVoiceOverRunning = UIAccessibility.isVoiceOverRunning

    var body: some View {
        ZStack {
            TPPPDFDocumentView(document: document, pdfView: pdfView, showingDocumentInfo: $showingDocumentInfo, isTracking: $isTracking)
                .edgesIgnoringSafeArea([.all])
                .accessibilityScrollAction { edge in
                    handleAccessibilityScroll(edge)
                }

            VStack {
                TPPPDFLabel(documentTitle)
                    .padding(.top)
                Spacer()
                if let pageLabel = document.page(at: metadata.currentPage)?.label, Int(pageLabel) != (metadata.currentPage + 1) {
                    TPPPDFLabel("\(pageLabel) (\(metadata.currentPage + 1)/\(document.pageCount))")
                } else {
                    TPPPDFLabel("\(metadata.currentPage + 1)/\(document.pageCount)")
                }
                if isVoiceOverRunning {
                    VStack(spacing: 0) {
                        Divider()
                        TPPPDFAccessibilityToolbar(
                            currentPage: $metadata.currentPage,
                            pageCount: document.pageCount
                        )
                    }
                } else {
                    // PP-1916: lazy thumbnail strip — only renders visible pages,
                    // replacing PDFKit's eager all-pages PDFThumbnailView.
                    PDFThumbnailStrip(document: document, currentPage: $metadata.currentPage)
                }
            }
            .opacity(showingDocumentInfo || isVoiceOverRunning ? 1 : 0)
        }
        .navigationBarHidden(!showingDocumentInfo && !isVoiceOverRunning)
        .onAppear {
            // PP-4297: DRM-protected titles must not expose Copy/Cut/Paste
            // on long-press. Applying here (rather than at field init)
            // because `metadata` is unavailable until the environment is
            // injected, and the view is mounted before any long-press
            // gesture can fire.
            pdfView.allowsCopy = !metadata.book.isDRMProtected
            documentTitle = resolveDocumentTitle()
        }
        .onReceive(pageChangePublisher) { value in
            if let pdfView = (value.object as? PDFView), let page = pdfView.currentPage, let pageIndex = pdfView.document?.index(for: page) {
                metadata.currentPage = pageIndex
                if isTracking {
                    showingDocumentInfo = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in
            isVoiceOverRunning = UIAccessibility.isVoiceOverRunning
        }
    }

    private func handleAccessibilityScroll(_ edge: Edge) {
        switch edge {
        case .trailing, .bottom:
            guard metadata.currentPage < document.pageCount - 1 else { return }
            metadata.currentPage += 1
        case .leading, .top:
            guard metadata.currentPage > 0 else { return }
            metadata.currentPage -= 1
        }
        let status = String(format: Strings.TPPBaseReaderViewController.pageOf, metadata.currentPage + 1) + "\(document.pageCount)"
        UIAccessibility.post(notification: .pageScrolled, argument: status)
    }

    /// Resolves the document title synchronously on the main actor.
    ///
    /// `complete` (structural fix): the prior `try? await document.title()` sent
    /// the non-`Sendable` PDFKit `PDFDocument` across the `await` boundary
    /// ("sending 'self.document' risks data races"), which `@preconcurrency import
    /// PDFKit` does not clear because the send is of the concrete document value,
    /// not a cross-module type-annotation issue. PDFKit exposes the title
    /// synchronously via `documentAttributes[.titleAttribute]` — the same read
    /// `TPPPDFDocument.title` performs — so we read it here on the current (main)
    /// actor without ever crossing an isolation boundary. `TPPPDFView` is a
    /// main-actor `View` and `document` is main-actor-held, so this is
    /// behavior-preserving and strictly cheaper (no Task/await hop).
    private func resolveDocumentTitle() -> String {
        let attributeTitle = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        return attributeTitle ?? metadata.book.title
    }
}
