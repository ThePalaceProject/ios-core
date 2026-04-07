//
//  TPPPDFView.swift
//  Palace
//
//  Created by Vladimir Fedorov on 31.05.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI
import PDFKit

/// This view shows PDFKit views when PDF is not encrypted
/// PDFKit reading controls (PDFView and PDFThumbnails) are generally faster because of direct data reading,
/// instead of reading blocks of data with data provider.
/// The analog for encrypted documents - `TPPEncryptedPDFView`
struct TPPPDFView: View {

    let document: PDFDocument
    let pdfView = PDFView()
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
                // PP-3838: Full Keyboard Access (Tab-Z menu) and VoiceOver rotor
                // custom actions for page navigation, mirroring the EPUB reader.
                .accessibilityAction(named: Text(Strings.Generic.nextPage)) {
                    advancePage(by: 1)
                }
                .accessibilityAction(named: Text(Strings.Generic.previousPage)) {
                    advancePage(by: -1)
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
                VStack(spacing: 0) {
                    Divider()
                    if isVoiceOverRunning {
                        TPPPDFAccessibilityToolbar(
                            currentPage: $metadata.currentPage,
                            pageCount: document.pageCount
                        )
                    } else {
                        TPPPDFThumbnailView(pdfView: pdfView)
                            .frame(maxHeight: 40)
                            .background(
                                Color(UIColor.systemBackground)
                                    .edgesIgnoringSafeArea(.bottom)
                            )
                    }
                }
            }
            .opacity(showingDocumentInfo || isVoiceOverRunning ? 1 : 0)
        }
        .navigationBarHidden(!showingDocumentInfo && !isVoiceOverRunning)
        .onAppear {
            Task {
                if let title = await fetchDocumentTitle() {
                    documentTitle = title
                }
            }
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
            advancePage(by: 1)
        case .leading, .top:
            advancePage(by: -1)
        }
    }

    /// Advances `metadata.currentPage` by `delta` (clamped) and posts a
    /// VoiceOver page-scrolled announcement. Shared by the scroll action,
    /// the FKA / rotor custom actions, and the visible toolbar.
    func advancePage(by delta: Int) {
        let target = metadata.currentPage + delta
        guard target >= 0, target < document.pageCount else { return }
        metadata.currentPage = target
        let status = String(format: Strings.TPPBaseReaderViewController.pageOf, metadata.currentPage + 1) + "\(document.pageCount)"
        UIAccessibility.post(notification: .pageScrolled, argument: status)
    }

    private func fetchDocumentTitle() async -> String? {
        try? await document.title() ?? metadata.book.title
    }
}
