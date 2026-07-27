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
/// queuing, and background-task lifetime.
///
/// Throttle bookkeeping previously lived in this class (a serial
/// `DispatchQueue` + `lastReadPositionUploadDate` + `queuedReadPosition`).
/// As of the PalaceReadingPosition migration that state is owned by
/// `RemotePositionWriter` and shared across EPUB, audiobook, and PDF.
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

    /// Retains every spawned server-post `Task` still in flight so tests can
    /// join the actual fire-and-forget work deterministically instead of
    /// racing a fixed wall-clock `Task.sleep` (which starves under parallel
    /// oversubscription). Behavior-identical in production: each Task is
    /// spawned and runs exactly as before; we merely hold references so
    /// `awaitPendingWrites()` can drain them. Access is serialized on the
    /// caller's actor (`storeReadPosition` / the test helper both run on the
    /// same isolation domain as the poster's owner).
    private var pendingWriteTasks: [Task<Void, Never>] = []

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
        bookRegistryProvider.setLocation(location, forIdentifier: book.identifier)

        guard let snapshot = makeSnapshot(from: locator) else { return }
        pendingWriteTasks.append(Task { [positionWriter] in
            _ = try? await positionWriter.save(snapshot)
        })
    }

    /// Test seam: awaits every server-post `Task` spawned since the last
    /// drain so a test can JOIN the actual writes instead of polling a
    /// wall-clock deadline. No-op in production (never called there).
    /// Returns once all pending writes have finished.
    /// Synchronous snapshot: hands the caller every server-post `Task` spawned
    /// since the last drain so a test can `await` them (join the actual writes).
    /// SYNC on purpose — an `async` seam on this non-Sendable poster would make
    /// `await poster.<seam>()` from a `@MainActor` test *send* the poster across
    /// an isolation boundary (Swift 6 data-race error); a sync call sends nothing,
    /// and `Task<Void, Never>` is Sendable so the caller can await the returned set.
    func pendingWriteTasksForTesting() -> [Task<Void, Never>] {
        let tasks = pendingWriteTasks
        pendingWriteTasks.removeAll()
        return tasks
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

    /// Serializes the Readium `Locator` into the wire-shaped DTO consumed
    /// by `PositionWriter`. EPUB's payload is the Readium-locator JSON;
    /// it round-trips through `TPPAnnotations.postReadingPosition`'s
    /// existing `selectorValue` parameter.
    private func makeSnapshot(from locator: Locator) -> PositionSnapshot? {
        guard let selectorValue = try? locator.jsonString() else { return nil }
        return PositionSnapshot(
            bookID: book.identifier,
            format: .epubLocator,
            payload: Data(selectorValue.utf8),
            timestamp: Date(),
            device: deviceID
        )
    }

}
