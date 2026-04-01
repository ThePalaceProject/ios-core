//
//  ShareableBookCard.swift
//  Palace
//
//  Created for Social Features — model for generating a shareable book card image.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import UIKit

/// Data needed to render a shareable book card image.
struct ShareableBookCard: Equatable {

    /// The book's cover image.
    let coverImage: UIImage?

    /// Book title.
    let title: String

    /// Book author.
    let author: String

    /// The user's star rating (1-5), or nil if unrated.
    let rating: Int?

    /// An optional user-supplied quote or note.
    let quote: String

    /// The branding text shown at the bottom of the card.
    static let brandingText = "Shared from Palace"

    init(
        coverImage: UIImage? = nil,
        title: String,
        author: String,
        rating: Int? = nil,
        quote: String = ""
    ) {
        self.coverImage = coverImage
        self.title = title
        self.author = author
        self.rating = rating
        self.quote = quote
    }
}
