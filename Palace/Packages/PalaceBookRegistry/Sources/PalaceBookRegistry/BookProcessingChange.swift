//
//  BookProcessingChange.swift
//  PalaceBookRegistry
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// A book's processing flag changed: a borrow or return started or ended, or
/// an open finished. Screens show or clear their spinner for that book.
// PUBLIC_INTENT: element type of the public `bookProcessingPublisher`; the app target reads it.
public struct BookProcessingChange: Equatable, Sendable {
    // PUBLIC_INTENT: read by app-target subscribers of `bookProcessingPublisher`.
    public let bookIdentifier: String
    // PUBLIC_INTENT: read by app-target subscribers of `bookProcessingPublisher`.
    public let isProcessing: Bool

    // PUBLIC_INTENT: app-target test doubles build changes to publish.
    public init(bookIdentifier: String, isProcessing: Bool) {
        self.bookIdentifier = bookIdentifier
        self.isProcessing = isProcessing
    }
}
