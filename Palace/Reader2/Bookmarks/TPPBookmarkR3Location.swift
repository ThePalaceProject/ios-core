//
//  TPPBookmarkR3Location.swift
//  Palace
//
//  Created by Maurice Carrier on 11/19/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import ReadiumShared
import PalaceBookModel

/// Immutable data-carrier describing a Reader-2 (Readium 3) reading position.
///
/// `Sendable` conformance is a genuine one, not a race-silencer: every stored
/// property is itself `Sendable` (`Int`, Readium's `Locator` which is declared
/// `Sendable`, and `Date`) and is `let` — never mutated after `init`. Every
/// construction site (see `TPPReadiumBookmark+R3`, `TPPReaderBookmarksBusinessLogic`)
/// builds a fresh instance and none mutates a property afterward. This lets the
/// value cross the `@MainActor` → nonisolated `addBookmark(_:)` boundary in
/// `TPPBaseReaderViewController.addBookmark(at:)` without a `sending` violation.
final class TPPBookmarkR3Location: Sendable {
    let resourceIndex: Int
    let locator: Locator
    let creationDate: Date

    init(resourceIndex: Int, locator: Locator, creationDate: Date = Date()) {
        self.resourceIndex = resourceIndex
        self.locator = locator
        self.creationDate = creationDate
    }
}

extension TPPBookmarkR3Location {
    /// Creates a `TPPBookmarkR3Location` from a given `Locator`.
    ///
    /// - Parameters:
    ///   - locator: The `Locator` representing the reading position.
    ///   - publication: The `Publication` containing the reading material.
    /// - Returns: An optional `TPPBookmarkR3Location` if the `Locator` resolves successfully.
    static func from(locator: Locator, in publication: Publication, creationDate: Date = Date()) -> TPPBookmarkR3Location? {
        let href = locator.href

        guard let resourceIndex = publication.readingOrder.firstIndex(where: { $0.href == href.string }) else {
            return nil
        }

        return TPPBookmarkR3Location(resourceIndex: resourceIndex, locator: locator, creationDate: creationDate)
    }
}
