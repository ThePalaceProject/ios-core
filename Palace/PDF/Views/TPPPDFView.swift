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
/// Encrypted (LCP) PDFs reach this same view: they are decrypted to disk and
/// opened through `TPPPDFDocument(url:)`. The former `TPPEncryptedPDFView` was
/// deleted with the LCP pipeline migration.
struct TPPPDFView: View {

    let document: PDFDocument
    // PP-4297: PalacePDFView subclass so we can gate Copy/Cut/Paste/Look
    // Up/Share on long-press when the book is DRM-protected. The
    // `allowsCopy` flag is applied below in `onAppear`, before any user
    // interaction can reach the view.
    //
    // TPPPDFView renders every PDF, encrypted included: LCP titles are
    // decrypted to disk first and arrive here as an ordinary PDFDocument,
    // so this gating is the live defence for DRM-protected text rather
    // than a forward-looking one.
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
                // PP-3838: Full Keyboard Access (the Tab-Z menu) needs named
                // actions; a scroll action alone is reachable only by a
                // three-finger swipe. Restores what #811 removed.
                //
                // Whether VoiceOver's rotor surfaces these is NOT established.
                // They sit on a `UIViewRepresentable` container, and UIKit
                // reads `accessibilityCustomActions` from the focused element
                // rather than walking ancestors — `accessibilityScroll:` does
                // propagate up, so the working scroll action above is not
                // evidence for these. The sibling reader registers the same
                // strings on its own container and a device recording refuted
                // it (PP-4527). PDFKit is not a WKWebView with a separate AX
                // tree, so it may well differ, but only a device can say.
                // Claim Tab-Z, not the rotor, until someone checks.
                //
                // Both delegate to the scroll handler so the boundary clamp
                // and the page announcement have one implementation.
                .accessibilityAction(named: Text(Strings.Generic.nextPage)) {
                    handleAccessibilityScroll(.bottom)
                }
                .accessibilityAction(named: Text(Strings.Generic.previousPage)) {
                    handleAccessibilityScroll(.top)
                }

            VStack {
                TPPPDFLabel(documentTitle)
                    .padding(.top)
                Spacer()
                SwiftUI.Group {
                    if let pageLabel = document.page(at: metadata.currentPage)?.label, Int(pageLabel) != (metadata.currentPage + 1) {
                        TPPPDFLabel("\(pageLabel) (\(metadata.currentPage + 1)/\(document.pageCount))")
                    } else {
                        TPPPDFLabel("\(metadata.currentPage + 1)/\(document.pageCount)")
                    }
                }
                .contentTransition(.numericText(value: Double(metadata.currentPage + 1)))
                .accessibleAnimation(PalaceMotion.standard, value: metadata.currentPage)
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
        let status = String(format: Strings.TPPBaseReaderViewController.pageOf, metadata.currentPage + 1, document.pageCount)
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
