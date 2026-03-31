//
//  BookReviewViewModel.swift
//  Palace
//
//  Created for Social Features — manages review creation and editing.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation

/// ViewModel for the book review editor sheet.
@MainActor
final class BookReviewViewModel: ObservableObject {

    // MARK: - Published State

    @Published var rating: Int = 0
    @Published var reviewText: String = ""
    @Published var existingReview: BookReview?
    @Published var isSaved: Bool = false

    // MARK: - Dependencies

    let bookID: String
    private let reviewService: BookReviewServiceProtocol
    private let activityService: ReadingActivityServiceProtocol?

    // MARK: - Init

    init(
        bookID: String,
        bookTitle: String? = nil,
        reviewService: BookReviewServiceProtocol,
        activityService: ReadingActivityServiceProtocol? = nil
    ) {
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.reviewService = reviewService
        self.activityService = activityService

        loadExistingReview()
    }

    // MARK: - Private

    private let bookTitle: String?

    private func loadExistingReview() {
        if let review = reviewService.review(forBookID: bookID) {
            existingReview = review
            rating = review.rating
            reviewText = review.reviewText
        }
    }

    // MARK: - Actions

    var canSave: Bool {
        rating >= 1 && rating <= 5
    }

    func saveReview() {
        guard canSave else { return }

        let review: BookReview
        if let existing = existingReview {
            review = BookReview(
                id: existing.id,
                bookID: bookID,
                rating: rating,
                reviewText: reviewText,
                createdDate: existing.createdDate,
                modifiedDate: Date()
            )
        } else {
            review = BookReview(
                bookID: bookID,
                rating: rating,
                reviewText: reviewText
            )
        }

        let saved = reviewService.saveReview(review)
        existingReview = saved
        isSaved = true

        // Record activity
        activityService?.recordActivity(ReadingActivity(
            type: .wroteReview,
            bookID: bookID,
            bookTitle: bookTitle,
            metadata: ["rating": "\(rating)"]
        ))
    }

    func deleteReview() {
        reviewService.deleteReview(forBookID: bookID)
        existingReview = nil
        rating = 0
        reviewText = ""
        isSaved = false
    }
}
