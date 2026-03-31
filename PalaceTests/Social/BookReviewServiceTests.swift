//
//  BookReviewServiceTests.swift
//  PalaceTests
//
//  Tests for BookReviewService save/update/delete and rating calculation.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import Palace

final class BookReviewServiceTests: XCTestCase {

    private var sut: BookReviewService!
    private var defaults: UserDefaults!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "BookReviewServiceTests")!
        defaults.removePersistentDomain(forName: "BookReviewServiceTests")
        sut = BookReviewService(userDefaults: defaults)
        cancellables = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "BookReviewServiceTests")
        defaults = nil
        sut = nil
        cancellables = nil
        super.tearDown()
    }

    // MARK: - Save

    func testSaveReview_CreatesNew() {
        let review = BookReview(bookID: "book-1", rating: 4, reviewText: "Great book!")
        let saved = sut.saveReview(review)
        XCTAssertEqual(saved.bookID, "book-1")
        XCTAssertEqual(saved.rating, 4)
        XCTAssertEqual(saved.reviewText, "Great book!")
    }

    func testSaveReview_UpdatesExisting() {
        let original = BookReview(bookID: "book-1", rating: 3)
        sut.saveReview(original)

        let updated = BookReview(bookID: "book-1", rating: 5, reviewText: "Changed my mind!")
        let result = sut.saveReview(updated)
        XCTAssertEqual(result.rating, 5)
        XCTAssertEqual(result.reviewText, "Changed my mind!")

        // Should still only have one review for this book
        XCTAssertEqual(sut.allReviews().filter { $0.bookID == "book-1" }.count, 1)
    }

    // MARK: - Delete

    func testDeleteReview_RemovesExisting() {
        sut.saveReview(BookReview(bookID: "book-1", rating: 3))
        XCTAssertTrue(sut.deleteReview(forBookID: "book-1"))
        XCTAssertNil(sut.review(forBookID: "book-1"))
    }

    func testDeleteReview_ReturnsFalseForMissing() {
        XCTAssertFalse(sut.deleteReview(forBookID: "nonexistent"))
    }

    // MARK: - Query

    func testReviewForBook_ReturnsCorrect() {
        sut.saveReview(BookReview(bookID: "book-1", rating: 4))
        sut.saveReview(BookReview(bookID: "book-2", rating: 2))
        let review = sut.review(forBookID: "book-1")
        XCTAssertEqual(review?.rating, 4)
    }

    func testReviewForBook_ReturnsNilForMissing() {
        XCTAssertNil(sut.review(forBookID: "nonexistent"))
    }

    func testAllReviews_SortedByModifiedDate() {
        let oldDate = Date(timeIntervalSince1970: 1000)
        let newDate = Date(timeIntervalSince1970: 2000)
        sut.saveReview(BookReview(bookID: "old", rating: 3, modifiedDate: oldDate))
        sut.saveReview(BookReview(bookID: "new", rating: 5, modifiedDate: newDate))
        let all = sut.allReviews()
        XCTAssertEqual(all.first?.bookID, "new")
    }

    // MARK: - Average Rating

    func testAverageRating_CalculatesCorrectly() {
        sut.saveReview(BookReview(bookID: "a", rating: 4))
        sut.saveReview(BookReview(bookID: "b", rating: 2))
        let avg = sut.averageRating()
        XCTAssertEqual(avg, 3.0)
    }

    func testAverageRating_NilWhenEmpty() {
        XCTAssertNil(sut.averageRating())
    }

    // MARK: - Rating Clamping

    func testRating_ClampedTo1Through5() {
        let low = BookReview(bookID: "low", rating: 0)
        XCTAssertEqual(low.rating, 1)

        let high = BookReview(bookID: "high", rating: 10)
        XCTAssertEqual(high.rating, 5)
    }

    // MARK: - Persistence

    func testPersistence_SurvivesReload() {
        sut.saveReview(BookReview(bookID: "persist", rating: 5, reviewText: "Excellent"))
        let reloaded = BookReviewService(userDefaults: defaults)
        let review = reloaded.review(forBookID: "persist")
        XCTAssertEqual(review?.rating, 5)
        XCTAssertEqual(review?.reviewText, "Excellent")
    }

    // MARK: - Publisher

    func testPublisher_EmitsOnSave() {
        let expectation = expectation(description: "Publisher emits")

        sut.reviewsPublisher
            .dropFirst()
            .sink { reviews in
                if reviews.contains(where: { $0.bookID == "pub-test" }) {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        sut.saveReview(BookReview(bookID: "pub-test", rating: 3))
        wait(for: [expectation], timeout: 1.0)
    }
}
