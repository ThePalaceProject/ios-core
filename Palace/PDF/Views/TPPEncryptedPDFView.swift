//
//  TPPEncryptedPDFView.swift
//  Palace
//
//  Created by Vladimir Fedorov on 20.05.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI

/// This view shows encrypted PDF documents.
/// The analog for non-encrypted documents - `TPPPDFView`
struct TPPEncryptedPDFView: View {

    let encryptedPDF: TPPEncryptedPDFDocument

    @EnvironmentObject var metadata: TPPPDFDocumentMetadata

    @State private var showingDocumentInfo = true
    @State private var isVoiceOverRunning = UIAccessibility.isVoiceOverRunning

    var body: some View {
        ZStack {
            TPPEncryptedPDFViewer(encryptedPDF: encryptedPDF, currentPage: $metadata.currentPage, showingDocumentInfo: $showingDocumentInfo)
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
                TPPPDFLabel(encryptedPDF.title ?? metadata.book.title)
                    .padding(.top)
                Spacer()
                TPPPDFLabel("\(metadata.currentPage + 1)/\(encryptedPDF.pageCount)")
                if isVoiceOverRunning {
                    TPPPDFAccessibilityToolbar(
                        currentPage: $metadata.currentPage,
                        pageCount: encryptedPDF.pageCount
                    )
                } else {
                    TPPPDFPreviewBar(document: encryptedPDF, currentPage: $metadata.currentPage)
                }
            }
            .opacity(showingDocumentInfo || isVoiceOverRunning ? 1 : 0)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                // TPPEncryptedPDFPageViewController doesn't receive double tap without this
            }
            .onTapGesture(count: 1) {
                showingDocumentInfo.toggle()
            }
        }
        .navigationBarHidden(!showingDocumentInfo && !isVoiceOverRunning)
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
        guard target >= 0, target < encryptedPDF.pageCount else { return }
        metadata.currentPage = target
        let status = String(format: Strings.TPPBaseReaderViewController.pageOf, metadata.currentPage + 1) + "\(encryptedPDF.pageCount)"
        UIAccessibility.post(notification: .pageScrolled, argument: status)
    }
}
