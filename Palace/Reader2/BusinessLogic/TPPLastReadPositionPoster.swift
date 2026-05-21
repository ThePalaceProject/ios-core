//
//  TPPLastReadPositionPoster.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 3/9/21.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

import Foundation
import ReadiumShared

/// A front-end to the Annotations API to post a new reading progress for a given book.
class TPPLastReadPositionPoster {
    /// Interval used to throttle request submission.
    static let throttlingInterval: TimeInterval = 15.0

    // Models
    private let publication: Publication
    private let book: TPPBook

    // External dependencies
    private let bookRegistryProvider: TPPBookRegistryProvider

    // Internal state management
    private var lastReadPositionUploadDate: Date
    private var queuedReadPosition: Locator?
    private let serialQueue = DispatchQueue(label: "\(Bundle.main.bundleIdentifier ?? "org.thepalaceproject.palace").lastReadPositionPoster", qos: .utility)

    init(book: TPPBook,
         publication: Publication,
         bookRegistryProvider: TPPBookRegistryProvider) {
        self.book = book
        self.publication = publication
        self.bookRegistryProvider = bookRegistryProvider
        self.lastReadPositionUploadDate = Date()
            .addingTimeInterval(-TPPLastReadPositionPoster.throttlingInterval)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(postQueuedReadPositionInSerialQueue),
                                               name: UIApplication.willResignActiveNotification,
                                               object: nil)
    }

    // MARK: - Storing

    /// Stores a new reading progress location on the server.
    /// - Parameter locator: The new local progress to be stored.
    func storeReadPosition(locator: Locator) {
        guard shouldStore(locator: locator) else { return }

        // Save location locally
        let location = TPPBookLocation(locator: locator, type: "LocatorHrefProgression", publication: publication)
        bookRegistryProvider.setLocation(location, forIdentifier: book.identifier)

        // Queue posting of this position
        postReadPosition(locator: locator)
    }

    /// Determines if a locator should be stored and posted.
    ///
    /// Contract (P0 #1, swarm `swarm_f3b9b087`):
    /// - **Reject** any locator with `totalProgression == nil`. Readium
    ///   emits an initial locator-change *before* the WKWebView has
    ///   laid out the document; `totalProgression` is nil at that point.
    ///   Persisting that locator overwrites the patron's real saved
    ///   position with pre-render junk and is the root cause of the
    ///   "opens at chapter 1" regression.
    /// - **Accept** any locator with `position` > 0 (PDF / fixed-layout
    ///   EPUB page index — a legitimate anchor independent of
    ///   continuous progression).
    /// - **Accept** any locator with `totalProgression` > 0 (mid-book).
    /// - **Accept** a locator with `totalProgression == 0.0` only when
    ///   paired with a `cssSelector` — the selector pinpoints an
    ///   in-chapter element (Readium-style CFI anchor), and the
    ///   non-nil progression confirms the page has rendered.
    /// - Otherwise reject.
    private func shouldStore(locator: Locator) -> Bool {
        // Reject pre-render junk: nil totalProgression means the WKWebView
        // hasn't reported layout metrics yet.
        guard let totalProgression = locator.locations.totalProgression else {
            return false
        }

        // Explicit positional anchor (PDF / fixed-layout EPUB page).
        if let position = locator.locations.position, position > 0 {
            return true
        }

        // Mid-book continuous progression.
        if totalProgression > 0 {
            return true
        }

        // First-paint cssSelector anchor — selector is meaningful only
        // when the page has actually rendered (totalProgression non-nil,
        // verified by the guard above).
        if locator.locations.otherLocations["cssSelector"] != nil {
            return true
        }

        return false
    }

    /// Queues the read position for posting.
    ///
    /// Requests are throttled to avoid excessive updates.
    private func postReadPosition(locator: Locator) {
        serialQueue.async { [weak self] in
            guard let self = self else { return }

            self.queuedReadPosition = locator

            if Date() > self.lastReadPositionUploadDate.addingTimeInterval(TPPLastReadPositionPoster.throttlingInterval) {
                self.postQueuedReadPosition()
            }
        }
    }

    private func postQueuedReadPosition() {
        guard let locator = self.queuedReadPosition, let selectorValue = locator.jsonString else { return }

        TPPAnnotations.postReadingPosition(forBook: book.identifier,
                                           selectorValue: selectorValue,
                                           motivation: .readingProgress)

        self.queuedReadPosition = nil
        self.lastReadPositionUploadDate = Date()
    }

    @objc private func postQueuedReadPositionInSerialQueue() {
        serialQueue.async { [weak self] in
            self?.postQueuedReadPosition()
        }
    }
}
