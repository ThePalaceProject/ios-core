//
//  BookReviewService.swift
//  Palace
//
//  Created for Social Features — local review persistence.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation

/// Manages locally stored book reviews via UserDefaults + JSON.
final class BookReviewService: BookReviewServiceProtocol {

    // MARK: - Storage

    private let userDefaults: UserDefaults
    private static let storageKey = "palace.social.bookReviews"

    // MARK: - Combine

    private let reviewsSubject: CurrentValueSubject<[BookReview], Never>

    var reviewsPublisher: AnyPublisher<[BookReview], Never> {
        reviewsSubject.eraseToAnyPublisher()
    }

    // MARK: - Init

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let loaded = Self.load(from: userDefaults)
        self.reviewsSubject = CurrentValueSubject(loaded)
    }

    // MARK: - CRUD

    @discardableResult
    func saveReview(_ review: BookReview) -> BookReview {
        var reviews = reviewsSubject.value

        if let index = reviews.firstIndex(where: { $0.bookID == review.bookID }) {
            var updated = review
            updated.modifiedDate = Date()
            reviews[index] = updated
            save(reviews)
            return updated
        } else {
            reviews.append(review)
            save(reviews)
            return review
        }
    }

    @discardableResult
    func deleteReview(forBookID bookID: String) -> Bool {
        var reviews = reviewsSubject.value
        let countBefore = reviews.count
        reviews.removeAll { $0.bookID == bookID }
        if reviews.count != countBefore {
            save(reviews)
            return true
        }
        return false
    }

    func review(forBookID bookID: String) -> BookReview? {
        reviewsSubject.value.first { $0.bookID == bookID }
    }

    func allReviews() -> [BookReview] {
        reviewsSubject.value.sorted { $0.modifiedDate > $1.modifiedDate }
    }

    // MARK: - Analytics

    func averageRating() -> Double? {
        let reviews = reviewsSubject.value
        guard !reviews.isEmpty else { return nil }
        let sum = reviews.reduce(0) { $0 + $1.rating }
        return Double(sum) / Double(reviews.count)
    }

    // MARK: - Persistence

    private func save(_ reviews: [BookReview]) {
        reviewsSubject.send(reviews)
        guard let data = try? JSONEncoder().encode(reviews) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }

    private static func load(from userDefaults: UserDefaults) -> [BookReview] {
        guard let data = userDefaults.data(forKey: storageKey),
              let reviews = try? JSONDecoder().decode([BookReview].self, from: data) else {
            return []
        }
        return reviews
    }
}
