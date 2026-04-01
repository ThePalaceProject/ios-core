//
//  BookReview.swift
//  Palace
//
//  Created for Social Features — local book reviews.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// A user's local review of a book (rating and optional text).
struct BookReview: Codable, Identifiable, Equatable {

    /// Unique identifier for the review.
    let id: UUID

    /// The book being reviewed.
    let bookID: String

    /// Star rating from 1 to 5.
    var rating: Int {
        didSet {
            rating = max(1, min(5, rating))
        }
    }

    /// Optional written review.
    var reviewText: String

    /// When the review was first created.
    let createdDate: Date

    /// When the review was last modified.
    var modifiedDate: Date

    init(
        id: UUID = UUID(),
        bookID: String,
        rating: Int,
        reviewText: String = "",
        createdDate: Date = Date(),
        modifiedDate: Date = Date()
    ) {
        self.id = id
        self.bookID = bookID
        self.rating = max(1, min(5, rating))
        self.reviewText = reviewText
        self.createdDate = createdDate
        self.modifiedDate = modifiedDate
    }

    /// Human-readable star display (e.g. "4 out of 5 stars").
    var accessibilityRatingLabel: String {
        "\(rating) out of 5 stars"
    }
}
