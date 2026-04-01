//
//  TPPPDFAccessibilityToolbar.swift
//  Palace
//
//  Created for PP-3838: Accessible page navigation for PDF Reader.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI

/// A bottom toolbar with Previous / Next page buttons, shown only when
/// VoiceOver is running. Mirrors the EPUB reader's accessibility toolbar
/// (TPPBaseReaderViewController) for consistent navigation (WCAG 3.2.3).
struct TPPPDFAccessibilityToolbar: View {

    @Binding var currentPage: Int
    let pageCount: Int

    private var canGoBack: Bool { currentPage > 0 }
    private var canGoForward: Bool { currentPage < pageCount - 1 }

    var body: some View {
        HStack {
            Button(action: goBackward) {
                Image(systemName: "backward.fill")
                    .imageScale(.large)
            }
            .disabled(!canGoBack)
            .accessibilityLabel(Strings.Generic.previousPage)

            Spacer()

            Text(pageStatus)
                .font(.caption)
                .foregroundColor(.secondary)
                .accessibilityLabel(pageStatus)

            Spacer()

            Button(action: goForward) {
                Image(systemName: "forward.fill")
                    .imageScale(.large)
            }
            .disabled(!canGoForward)
            .accessibilityLabel(Strings.Generic.nextPage)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(
            Color(UIColor.systemBackground)
                .edgesIgnoringSafeArea(.bottom)
        )
    }

    private var pageStatus: String {
        String(format: Strings.TPPBaseReaderViewController.pageOf, currentPage + 1) + "\(pageCount)"
    }

    private func goBackward() {
        guard canGoBack else { return }
        currentPage -= 1
        announcePageChange()
    }

    private func goForward() {
        guard canGoForward else { return }
        currentPage += 1
        announcePageChange()
    }

    private func announcePageChange() {
        let status = pageStatus
        UIAccessibility.post(notification: .pageScrolled, argument: status)
    }
}
