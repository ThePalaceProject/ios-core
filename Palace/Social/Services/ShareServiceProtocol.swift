//
//  ShareServiceProtocol.swift
//  Palace
//
//  Created for Social Features — share service contract.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import UIKit

/// Contract for generating shareable content from books.
protocol ShareServiceProtocol {

    /// Generates a human-readable share text for a book.
    func shareText(for book: TPPBook) -> String

    /// Generates a deep link URL for a book.
    func deepLink(for book: TPPBook) -> URL?

    /// Renders a shareable card image from the given card model.
    func renderShareCard(_ card: ShareableBookCard) -> UIImage?

    /// Builds the array of items suitable for UIActivityViewController.
    func shareItems(for book: TPPBook, cardImage: UIImage?) -> [Any]
}
