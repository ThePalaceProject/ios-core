//
//  ShareViewModel.swift
//  Palace
//
//  Created for Social Features — manages share sheet preparation.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import UIKit

/// ViewModel for preparing share content for a book.
@MainActor
final class ShareViewModel: ObservableObject {

    // MARK: - Published State

    @Published var shareItems: [Any] = []
    @Published var shareCardImage: UIImage?
    @Published var isReady: Bool = false

    // MARK: - Dependencies

    private let shareService: ShareServiceProtocol

    // MARK: - Init

    init(shareService: ShareServiceProtocol) {
        self.shareService = shareService
    }

    // MARK: - Actions

    func prepareShare(for book: TPPBook) {
        let items = shareService.shareItems(for: book, cardImage: shareCardImage)
        shareItems = items
        isReady = true
    }

    func generateShareCard(
        for book: TPPBook,
        withRating rating: Int? = nil,
        quote: String = ""
    ) {
        let card = ShareableBookCard(
            coverImage: book.coverImage,
            title: book.title,
            author: book.authors ?? "",
            rating: rating,
            quote: quote
        )
        shareCardImage = shareService.renderShareCard(card)
    }

    func reset() {
        shareItems = []
        shareCardImage = nil
        isReady = false
    }
}
