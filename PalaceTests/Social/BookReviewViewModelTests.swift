//
//  BookReviewViewModelTests.swift
//  PalaceTests
//
//  Tests for BookReviewViewModel save/load/delete flow.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import Palace

@MainActor
final class BookReviewViewModelTests: XCTestCase {

    private var sut: BookReviewViewModel!
    private var mockReviewService: MockBookReviewService!
    private var mockActivityService: MockReadingActivityService!

    override func setUp() {
        super.setUp()
        mockReviewService = MockBookReviewService()
        mockActivityService = MockReadingActivityService()
    }

    override func tearDown() {
        sut = nil
        mockReviewService = nil
        mockActivityService = nil
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialState_NoExistingReview() {
        sut = BookReviewViewModel(
            bookID: "book-1",
            reviewService: mockReviewService,
            activityService: mockActivityService
        )
        XCTAssertEqual(sut.rating, 0)
        XCTAssertEqual(sut.reviewText, "")
        XCTAssertNil(sut.existingReview)
        XCTAssertFalse(sut.isSaved)
    }

    func testInitialState_LoadsExistingReview() {
        mockReviewService.saveReview(BookReview(bookID: "book-1", rating: 4, reviewText: "Good"))
        sut = BookReviewViewModel(
            bookID: "book-1",
            reviewService: mockReviewService,
            activityService: mockActivityService
        )
        XCTAssertEqual(sut.rating, 4)
        XCTAssertEqual(sut.reviewText, "Good")
        XCTAssertNotNil(sut.existingReview)
    }

    // MARK: - Can Save

    func testCanSave_FalseWhenNoRating() {
        sut = BookReviewViewModel(bookID: "book-1", reviewService: mockReviewService)
        XCTAssertFalse(sut.canSave)
    }

    func testCanSave_TrueWhenRatingSet() {
        sut = BookReviewViewModel(bookID: "book-1", reviewService: mockReviewService)
        sut.rating = 3
        XCTAssertTrue(sut.canSave)
    }

    // MARK: - Save

    func testSaveReview_PersistsToService() {
        sut = BookReviewViewModel(
            bookID: "book-1",
            bookTitle: "Test Book",
            reviewService: mockReviewService,
            activityService: mockActivityService
        )
        sut.rating = 5
        sut.reviewText = "Amazing!"
        sut.saveReview()

        let review = mockReviewService.review(forBookID: "book-1")
        XCTAssertNotNil(review)
        XCTAssertEqual(review?.rating, 5)
        XCTAssertEqual(review?.reviewText, "Amazing!")
        XCTAssertTrue(sut.isSaved)
    }

    func testSaveReview_RecordsActivity() {
        sut = BookReviewViewModel(
            bookID: "book-1",
            bookTitle: "Test Book",
            reviewService: mockReviewService,
            activityService: mockActivityService
        )
        sut.rating = 4
        sut.saveReview()

        XCTAssertEqual(mockActivityService.recordedActivities.count, 1)
        XCTAssertEqual(mockActivityService.recordedActivities.first?.type, .wroteReview)
    }

    func testSaveReview_UpdatesExisting() {
        mockReviewService.saveReview(BookReview(bookID: "book-1", rating: 3))
        sut = BookReviewViewModel(bookID: "book-1", reviewService: mockReviewService)
        sut.rating = 5
        sut.saveReview()

        let review = mockReviewService.review(forBookID: "book-1")
        XCTAssertEqual(review?.rating, 5)
    }

    // MARK: - Delete

    func testDeleteReview_ClearsState() {
        mockReviewService.saveReview(BookReview(bookID: "book-1", rating: 4))
        sut = BookReviewViewModel(bookID: "book-1", reviewService: mockReviewService)
        sut.deleteReview()

        XCTAssertNil(sut.existingReview)
        XCTAssertEqual(sut.rating, 0)
        XCTAssertEqual(sut.reviewText, "")
        XCTAssertFalse(sut.isSaved)
        XCTAssertNil(mockReviewService.review(forBookID: "book-1"))
    }
}

// MARK: - Mock Review Service

final class MockBookReviewService: BookReviewServiceProtocol {
    private let subject = CurrentValueSubject<[BookReview], Never>([])

    var reviewsPublisher: AnyPublisher<[BookReview], Never> {
        subject.eraseToAnyPublisher()
    }

    @discardableResult
    func saveReview(_ review: BookReview) -> BookReview {
        var reviews = subject.value
        if let index = reviews.firstIndex(where: { $0.bookID == review.bookID }) {
            reviews[index] = review
        } else {
            reviews.append(review)
        }
        subject.send(reviews)
        return review
    }

    @discardableResult
    func deleteReview(forBookID bookID: String) -> Bool {
        var reviews = subject.value
        let before = reviews.count
        reviews.removeAll { $0.bookID == bookID }
        subject.send(reviews)
        return reviews.count != before
    }

    func review(forBookID bookID: String) -> BookReview? {
        subject.value.first { $0.bookID == bookID }
    }

    func allReviews() -> [BookReview] {
        subject.value.sorted { $0.modifiedDate > $1.modifiedDate }
    }

    func averageRating() -> Double? {
        let reviews = subject.value
        guard !reviews.isEmpty else { return nil }
        return Double(reviews.reduce(0) { $0 + $1.rating }) / Double(reviews.count)
    }
}

// MARK: - Mock Activity Service

final class MockReadingActivityService: ReadingActivityServiceProtocol {
    private let subject = CurrentValueSubject<[ReadingActivity], Never>([])
    var recordedActivities: [ReadingActivity] = []

    var activitiesPublisher: AnyPublisher<[ReadingActivity], Never> {
        subject.eraseToAnyPublisher()
    }

    func recordActivity(_ activity: ReadingActivity) {
        recordedActivities.append(activity)
        subject.send(recordedActivities)
    }

    func allActivities() -> [ReadingActivity] {
        recordedActivities.sorted { $0.timestamp > $1.timestamp }
    }

    func activities(ofType type: ReadingActivity.ActivityType) -> [ReadingActivity] {
        allActivities().filter { $0.type == type }
    }

    func activityCount() -> Int {
        recordedActivities.count
    }
}
