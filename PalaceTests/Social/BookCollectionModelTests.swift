//
//  BookCollectionModelTests.swift
//  PalaceTests
//
//  Tests for Social feature model types: BookCollection, BookRecommendation,
//  ReadingActivity, BookReview, ShareableBookCard.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class BookCollectionModelTests: XCTestCase {

    // MARK: - BookCollection Codable

    func testBookCollection_CodableRoundTrip() throws {
        let original = BookCollection(
            name: "My List",
            collectionDescription: "Some books I like",
            bookIDs: ["b1", "b2"],
            isPublic: true,
            sortOrder: 3
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BookCollection.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.collectionDescription, original.collectionDescription)
        XCTAssertEqual(decoded.bookIDs, original.bookIDs)
        XCTAssertEqual(decoded.isPublic, original.isPublic)
        XCTAssertEqual(decoded.sortOrder, original.sortOrder)
    }

    func testBookCollection_Equatable() {
        let id = UUID()
        let date = Date()
        let a = BookCollection(id: id, name: "A", createdDate: date, modifiedDate: date)
        let b = BookCollection(id: id, name: "A", createdDate: date, modifiedDate: date)
        XCTAssertEqual(a, b)
    }

    // MARK: - Default Collections

    func testDefaultCollections_HaveCorrectNames() {
        let defaults = BookCollection.createDefaults()
        let names = defaults.map(\.name)

        XCTAssertTrue(names.contains("Want to Read"))
        XCTAssertTrue(names.contains("Favorites"))
        XCTAssertTrue(names.contains("Finished"))
    }

    func testDefaultCollections_HaveIncrementingSortOrder() {
        let defaults = BookCollection.createDefaults()

        for i in 0..<defaults.count {
            XCTAssertEqual(defaults[i].sortOrder, i)
        }
    }

    func testDefaultCollections_AreMarkedAsDefault() {
        let defaults = BookCollection.createDefaults()
        XCTAssertTrue(defaults.allSatisfy(\.isDefault))
    }

    func testCustomCollection_IsNotDefault() {
        let custom = BookCollection(name: "My Custom")
        XCTAssertFalse(custom.isDefault)
    }

    // MARK: - BookCollection Helpers

    func testBookCount_ReflectsBookIDs() {
        let collection = BookCollection(name: "Test", bookIDs: ["a", "b", "c"])
        XCTAssertEqual(collection.bookCount, 3)
    }

    func testBookCount_EmptyCollection() {
        let collection = BookCollection(name: "Empty")
        XCTAssertEqual(collection.bookCount, 0)
    }

    func testContains_ReturnsTrueForPresentBook() {
        let collection = BookCollection(name: "Test", bookIDs: ["book-1", "book-2"])
        XCTAssertTrue(collection.contains(bookID: "book-1"))
    }

    func testContains_ReturnsFalseForAbsentBook() {
        let collection = BookCollection(name: "Test", bookIDs: ["book-1"])
        XCTAssertFalse(collection.contains(bookID: "book-99"))
    }

    // MARK: - BookRecommendation Codable

    func testBookRecommendation_CodableRoundTrip() throws {
        let original = BookRecommendation(
            bookID: "rec-book",
            bookTitle: "Recommended Book",
            bookAuthor: "Jane Author",
            note: "You'll love this!",
            fromUserName: "Alice"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BookRecommendation.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.bookID, original.bookID)
        XCTAssertEqual(decoded.bookTitle, original.bookTitle)
        XCTAssertEqual(decoded.bookAuthor, original.bookAuthor)
        XCTAssertEqual(decoded.note, original.note)
        XCTAssertEqual(decoded.fromUserName, original.fromUserName)
    }

    func testBookRecommendation_Equatable() {
        let id = UUID()
        let date = Date()
        let a = BookRecommendation(id: id, bookID: "b", bookTitle: "T", bookAuthor: "A", createdDate: date)
        let b = BookRecommendation(id: id, bookID: "b", bookTitle: "T", bookAuthor: "A", createdDate: date)
        XCTAssertEqual(a, b)
    }

    // MARK: - ReadingActivity Type Coverage

    func testReadingActivity_AllCasesExist() {
        let allCases = ReadingActivity.ActivityType.allCases
        XCTAssertEqual(allCases.count, 5)
        XCTAssertTrue(allCases.contains(.startedReading))
        XCTAssertTrue(allCases.contains(.finishedBook))
        XCTAssertTrue(allCases.contains(.earnedBadge))
        XCTAssertTrue(allCases.contains(.addedToCollection))
        XCTAssertTrue(allCases.contains(.wroteReview))
    }

    // MARK: - ReadingActivity Display Text

    func testDisplayText_StartedReading_WithTitle() {
        let activity = ReadingActivity(type: .startedReading, bookTitle: "Moby Dick")
        XCTAssertEqual(activity.displayText, "Started reading Moby Dick")
    }

    func testDisplayText_StartedReading_WithoutTitle() {
        let activity = ReadingActivity(type: .startedReading)
        XCTAssertEqual(activity.displayText, "Started reading a book")
    }

    func testDisplayText_FinishedBook_WithTitle() {
        let activity = ReadingActivity(type: .finishedBook, bookTitle: "1984")
        XCTAssertEqual(activity.displayText, "Finished 1984")
    }

    func testDisplayText_FinishedBook_WithoutTitle() {
        let activity = ReadingActivity(type: .finishedBook)
        XCTAssertEqual(activity.displayText, "Finished a book")
    }

    func testDisplayText_EarnedBadge_WithMetadata() {
        let activity = ReadingActivity(
            type: .earnedBadge,
            metadata: ["badgeName": "Bookworm"]
        )
        XCTAssertEqual(activity.displayText, "Earned Bookworm")
    }

    func testDisplayText_EarnedBadge_WithoutMetadata() {
        let activity = ReadingActivity(type: .earnedBadge)
        XCTAssertEqual(activity.displayText, "Earned a badge")
    }

    func testDisplayText_AddedToCollection_WithTitleAndMetadata() {
        let activity = ReadingActivity(
            type: .addedToCollection,
            bookTitle: "Dune",
            metadata: ["collectionName": "Sci-Fi"]
        )
        XCTAssertEqual(activity.displayText, "Added Dune to Sci-Fi")
    }

    func testDisplayText_AddedToCollection_WithoutTitle() {
        let activity = ReadingActivity(
            type: .addedToCollection,
            metadata: ["collectionName": "Favorites"]
        )
        XCTAssertEqual(activity.displayText, "Added a book to Favorites")
    }

    func testDisplayText_WroteReview_WithTitle() {
        let activity = ReadingActivity(type: .wroteReview, bookTitle: "Hamlet")
        XCTAssertEqual(activity.displayText, "Reviewed Hamlet")
    }

    func testDisplayText_WroteReview_WithoutTitle() {
        let activity = ReadingActivity(type: .wroteReview)
        XCTAssertEqual(activity.displayText, "Wrote a review")
    }

    // MARK: - ReadingActivity SF Symbol Mapping

    func testIconName_StartedReading() {
        let activity = ReadingActivity(type: .startedReading)
        XCTAssertEqual(activity.iconName, "book.fill")
    }

    func testIconName_FinishedBook() {
        let activity = ReadingActivity(type: .finishedBook)
        XCTAssertEqual(activity.iconName, "checkmark.circle.fill")
    }

    func testIconName_EarnedBadge() {
        let activity = ReadingActivity(type: .earnedBadge)
        XCTAssertEqual(activity.iconName, "star.circle.fill")
    }

    func testIconName_AddedToCollection() {
        let activity = ReadingActivity(type: .addedToCollection)
        XCTAssertEqual(activity.iconName, "folder.badge.plus")
    }

    func testIconName_WroteReview() {
        let activity = ReadingActivity(type: .wroteReview)
        XCTAssertEqual(activity.iconName, "text.quote")
    }

    // MARK: - ReadingActivity Codable

    func testReadingActivity_CodableRoundTrip() throws {
        let original = ReadingActivity(
            type: .addedToCollection,
            bookID: "b1",
            bookTitle: "Book",
            metadata: ["collectionName": "Favs"]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReadingActivity.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.type, original.type)
        XCTAssertEqual(decoded.bookID, original.bookID)
        XCTAssertEqual(decoded.bookTitle, original.bookTitle)
        XCTAssertEqual(decoded.metadata, original.metadata)
    }

    // MARK: - BookReview Rating Clamping

    func testBookReview_RatingClampedAbove5() {
        let review = BookReview(bookID: "b1", rating: 10)
        XCTAssertEqual(review.rating, 5)
    }

    func testBookReview_RatingClampedBelow1() {
        let review = BookReview(bookID: "b1", rating: -3)
        XCTAssertEqual(review.rating, 1)
    }

    func testBookReview_RatingClampedAtZero() {
        let review = BookReview(bookID: "b1", rating: 0)
        XCTAssertEqual(review.rating, 1)
    }

    func testBookReview_ValidRatingUnchanged() {
        let review = BookReview(bookID: "b1", rating: 3)
        XCTAssertEqual(review.rating, 3)
    }

    func testBookReview_BoundaryRating1() {
        let review = BookReview(bookID: "b1", rating: 1)
        XCTAssertEqual(review.rating, 1)
    }

    func testBookReview_BoundaryRating5() {
        let review = BookReview(bookID: "b1", rating: 5)
        XCTAssertEqual(review.rating, 5)
    }

    // MARK: - BookReview Codable

    func testBookReview_CodableRoundTrip() throws {
        let original = BookReview(
            bookID: "review-book",
            rating: 4,
            reviewText: "Great read!"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BookReview.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.bookID, original.bookID)
        XCTAssertEqual(decoded.rating, original.rating)
        XCTAssertEqual(decoded.reviewText, original.reviewText)
    }

    func testBookReview_AccessibilityLabel() {
        let review = BookReview(bookID: "b1", rating: 4)
        XCTAssertEqual(review.accessibilityRatingLabel, "4 out of 5 stars")
    }

    // MARK: - ShareableBookCard

    func testShareableBookCard_Initialization() {
        let card = ShareableBookCard(
            title: "Test Title",
            author: "Test Author",
            rating: 3,
            quote: "A great quote"
        )

        XCTAssertEqual(card.title, "Test Title")
        XCTAssertEqual(card.author, "Test Author")
        XCTAssertEqual(card.rating, 3)
        XCTAssertEqual(card.quote, "A great quote")
        XCTAssertNil(card.coverImage)
    }

    func testShareableBookCard_DefaultValues() {
        let card = ShareableBookCard(title: "Title", author: "Author")
        XCTAssertNil(card.coverImage)
        XCTAssertNil(card.rating)
        XCTAssertEqual(card.quote, "")
    }

    func testShareableBookCard_BrandingText() {
        XCTAssertEqual(ShareableBookCard.brandingText, "Shared from Palace")
    }

    func testShareableBookCard_Equatable() {
        let a = ShareableBookCard(title: "T", author: "A", rating: 3, quote: "Q")
        let b = ShareableBookCard(title: "T", author: "A", rating: 3, quote: "Q")
        XCTAssertEqual(a, b)
    }

    func testShareableBookCard_NotEqual_DifferentRating() {
        let a = ShareableBookCard(title: "T", author: "A", rating: 3)
        let b = ShareableBookCard(title: "T", author: "A", rating: 4)
        XCTAssertNotEqual(a, b)
    }
}
