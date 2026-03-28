//
//  ShareBookButton.swift
//  Palace
//
//  Created for Social Features — reusable share button for a book.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI

/// A button that triggers a share sheet for a given book.
/// Drop this into any book detail screen or toolbar.
struct ShareBookButton: View {
    let book: TPPBook
    let shareService: ShareServiceProtocol
    let reviewService: BookReviewServiceProtocol?

    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []

    init(
        book: TPPBook,
        shareService: ShareServiceProtocol = ShareService(),
        reviewService: BookReviewServiceProtocol? = nil
    ) {
        self.book = book
        self.shareService = shareService
        self.reviewService = reviewService
    }

    var body: some View {
        Button {
            prepareAndShare()
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .accessibilityLabel("Share \(book.title)")
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
    }

    private func prepareAndShare() {
        // Generate card with rating if available
        var cardImage: UIImage? = nil
        let rating = reviewService?.review(forBookID: book.identifier)?.rating
        let card = ShareableBookCard(
            coverImage: book.coverImage,
            title: book.title,
            author: book.authors ?? "",
            rating: rating
        )
        cardImage = shareService.renderShareCard(card)

        shareItems = shareService.shareItems(for: book, cardImage: cardImage)
        showShareSheet = true
    }
}
