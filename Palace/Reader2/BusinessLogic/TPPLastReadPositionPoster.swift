//
//  TPPLastReadPositionPoster.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 3/9/21.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

import Foundation
import PalaceReadingPosition
import ReadiumShared
import PalaceBookModel
import PalaceBookRegistry

/// A front-end to the position-write path that builds an EPUB-shaped
/// `PositionSnapshot` and delegates to a `PositionWriter` for throttling,
/// queuing, and background-task lifetime (shared across EPUB, audiobook and
/// PDF).
class TPPLastReadPositionPoster {
    /// Interval used to throttle request submission. Retained as a public
    /// constant so `PalaceTests/Reader/EPUBPositionTests` can pin the
    /// 15-second contract without reaching into the SPM.
    static let throttlingInterval: TimeInterval = 15.0

    // Models
    private let publication: Publication
    private let book: TPPBook

    // External dependencies
    private let bookRegistryProvider: TPPBookRegistryProvider
    private let positionWriter: PositionWriter
    private let deviceID: String

    /// Server-post `Task`s that are still running. Each one removes itself when
    /// it finishes, so a long reading session does not keep a handle per page
    /// turn (PP-5554), and tests can still join the live work.
    private let writeTasks = OwnedTaskRegistry()

    init(book: TPPBook,
         publication: Publication,
         bookRegistryProvider: TPPBookRegistryProvider,
         positionWriter: PositionWriter? = nil) {
        self.book = book
        self.publication = publication
        self.bookRegistryProvider = bookRegistryProvider
        self.positionWriter = positionWriter ?? EPUBPositionWriterFactory.make(for: book)
        self.deviceID = AnnotationDevice.currentID()
    }

    // MARK: - Storing

    /// Stores a new reading progress location on the server.
    ///
    /// Local save is synchronous; the server-side post is delegated to the
    /// injected `PositionWriter`, which throttles and queues internally.
    /// - Parameter locator: The new local progress to be stored.
    func storeReadPosition(locator: Locator) {
        guard shouldStore(locator: locator) else { return }

        // Save location locally
        let location = TPPBookLocation(locator: locator, type: "LocatorHrefProgression", publication: publication)
        // Page turns arrive in bursts; the registry keeps memory current and
        // limits the file rewrite to once per 15 s (PP-5507).
        bookRegistryProvider.setLocation(location, forIdentifier: book.identifier, persistence: .coalesced)

        // PP-5138: post the SAME bytes we just stored. See `makeSnapshot`.
        guard let snapshot = makeSnapshot(from: location) else { return }
        let token = UUID()
        let registry = writeTasks
        let task = Task { [positionWriter] in
            defer { registry.complete(token) }
            _ = try? await positionWriter.save(snapshot)
        }
        registry.register(token, task)
    }

    /// Stores the reader's last locator and writes any position still waiting
    /// for its disk write. Called when the reader closes.
    func storeFinalPositionAndFlush(locator: Locator?) {
        if let locator {
            storeReadPosition(locator: locator)
        }
        bookRegistryProvider.flushPendingPositions()
    }

    /// Test seam: returns the server-post `Task`s that are still running so a
    /// test can await them. A post that already finished is not returned, and
    /// needs no join. Synchronous on purpose: an `async` seam would send this
    /// non-Sendable poster across an isolation boundary.
    func pendingWriteTasksForTesting() -> [Task<Void, Never>] {
        writeTasks.snapshot().map { $0.1 }
    }

    /// Test seam: the number of server posts the poster still holds.
    var liveWriteTaskCountForTesting: Int {
        writeTasks.count
    }

    /// Determines if a locator should be stored and posted.
    ///
    /// Contract:
    /// - **Reject** any locator with `totalProgression == nil`. Readium
    ///   emits an initial locator-change before the WKWebView has laid out
    ///   the document; persisting it would overwrite the patron's saved
    ///   position ("opens at chapter 1").
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

    /// Serializes the position into the wire-shaped DTO consumed by
    /// `PositionWriter`, which hands the payload to
    /// `TPPAnnotations.postReadingPosition` as the annotation's
    /// `selector.value`.
    ///
    /// The payload is the `TPPBookLocation` string — a `LocatorHrefProgression`
    /// as defined by `ThePalaceProject/mobile-specs`:
    ///
    ///     {"@type":"LocatorHrefProgression","href":…,"progressWithinChapter":…}
    ///
    /// PP-5138: a raw Readium `Locator` has no `@type`, which Android reads as
    /// `LocatorLegacyCFI` and discards for EPUBs. Extra keys (`position`,
    /// `progressWithinBook`, `title`, `cssSelector`) are allowed by the schema
    /// and ignored by Android.
    private func makeSnapshot(from location: TPPBookLocation?) -> PositionSnapshot? {
        guard let location else { return nil }
        return PositionSnapshot(
            bookID: book.identifier,
            format: .epubLocator,
            payload: Data(location.locationString.utf8),
            timestamp: Date(),
            device: deviceID
        )
    }

}
