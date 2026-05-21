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
        Task { [positionWriter] in
            _ = try? await positionWriter.save(snapshot)
        }
    }

    /// Determines if a locator should be stored and posted. EPUB-specific:
    /// requires non-zero progression OR a `cssSelector` to be a meaningful
    /// position (avoids persisting the trivial "beginning of chapter"
    /// every time a reader opens a book).
    private func shouldStore(locator: Locator) -> Bool {
        let progression = locator.locations.totalProgression ?? 0
        return progression > 0 || locator.locations.otherLocations["cssSelector"] != nil
    }

    /// Serializes the Readium `Locator` into the wire-shaped DTO consumed
    /// by `PositionWriter`. EPUB's payload is the Readium-locator JSON;
    /// it round-trips through `TPPAnnotations.postReadingPosition`'s
    /// existing `selectorValue` parameter.
    private func makeSnapshot(from locator: Locator) -> PositionSnapshot? {
        guard let selectorValue = locator.jsonString else { return nil }
        return PositionSnapshot(
            bookID: book.identifier,
            format: .epubLocator,
            payload: Data(selectorValue.utf8),
            timestamp: Date(),
            device: deviceID
        )
    }

}
