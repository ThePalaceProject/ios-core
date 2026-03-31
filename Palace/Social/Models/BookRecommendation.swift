//
//  BookRecommendation.swift
//  Palace
//
//  Created for Social Features — book recommendations between users.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// A recommendation of a book, either to another user or saved for self.
struct BookRecommendation: Codable, Identifiable, Equatable {

    /// Unique identifier for this recommendation.
    let id: UUID

    /// The identifier of the recommended book.
    let bookID: String

    /// The title of the book (denormalized for display without lookup).
    let bookTitle: String

    /// The author of the book (denormalized for display).
    let bookAuthor: String

    /// Free-text note from the recommender (e.g. "You'll love this!").
    var note: String

    /// Display name of the person who made the recommendation.
    let fromUserName: String

    /// When the recommendation was created.
    let createdDate: Date

    init(
        id: UUID = UUID(),
        bookID: String,
        bookTitle: String,
        bookAuthor: String,
        note: String = "",
        fromUserName: String = "",
        createdDate: Date = Date()
    ) {
        self.id = id
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.bookAuthor = bookAuthor
        self.note = note
        self.fromUserName = fromUserName
        self.createdDate = createdDate
    }
}
