//
//  BookReviewServiceProtocol.swift
//  Palace
//
//  Created for Social Features — review service contract.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation

/// Contract for managing local book reviews.
protocol BookReviewServiceProtocol {

    /// Publisher that emits whenever any review changes.
    var reviewsPublisher: AnyPublisher<[BookReview], Never> { get }

    /// Saves or updates a review. If a review for the same bookID exists, it is updated.
    @discardableResult
    func saveReview(_ review: BookReview) -> BookReview

    /// Deletes the review for the given book ID. Returns true if a review was deleted.
    @discardableResult
    func deleteReview(forBookID bookID: String) -> Bool

    /// Returns the review for the given book, or nil.
    func review(forBookID bookID: String) -> BookReview?

    /// Returns all reviews sorted by modification date (newest first).
    func allReviews() -> [BookReview]

    /// Calculates the average rating across all reviews, or nil if none.
    func averageRating() -> Double?
}
