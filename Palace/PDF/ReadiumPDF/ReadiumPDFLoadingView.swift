//
//  ReadiumPDFLoadingView.swift
//  Palace
//
//  Shown when the user has tapped Read on an LCP PDF and the publication
//  is still being opened by Readium. LCP open on large Marketplace
//  containers involves hundreds of synchronous AES decrypt calls
//  (`TPPLCPClient.swift: Successfully decrypted 2064 bytes -> 2048 bytes`)
//  and can take 30-60s. Without this view the user would sit on the book
//  detail page during that window with only the Read button's small
//  spinner — feels frozen. Pushing the route immediately and showing a
//  full-screen loader here gives the user clear feedback that the open
//  is in progress.
//

import SwiftUI
import PalaceUIKit

struct ReadiumPDFLoadingView: View {
    let book: TPPBook

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.5)
                .padding(.bottom, 8)
            Text(book.title)
                .palaceFont(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Text(Strings.TPPPDFNavigation.loadingPDF)
                .palaceFont(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .ignoresSafeArea(edges: .bottom)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(book.title), \(Strings.TPPPDFNavigation.loadingPDF)")
    }
}
