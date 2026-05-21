//
//  EPUBPositionAdapter.swift
//  The Palace Project
//
//  Bridges `PositionWriter` to the legacy `TPPAnnotations` static-class
//  surface. Lives in the Palace target (NOT in the SPM) so the SPM stays
//  free of any `TPPAnnotations` / `TPPNetworkExecutor` dependency.
//
//  Used by `TPPLastReadPositionPoster`, `TPPLastReadPositionSynchronizer`,
//  and `TPPPDFDocumentMetadata` — the network endpoint is identical across
//  EPUB and PDF, so one adapter serves both formats.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceReadingPosition

/// Bridges `PositionNetworkAdapter` to the existing `TPPAnnotations` API.
///
/// `post(_:)` calls `TPPAnnotations.postReadingPosition` with the snapshot's
/// payload decoded as a UTF-8 string (the existing API's `selectorValue`).
/// `fetch(bookID:)` calls `TPPAnnotations.syncReadingPosition` and maps the
/// returned `TPPReadiumBookmark` back into a `PositionSnapshot` carrying the
/// server's location string + device identifier.
final class EPUBPositionAdapter: PositionNetworkAdapter, @unchecked Sendable {

    /// Provider for the book a `fetch` is being made against. The legacy
    /// `TPPAnnotations.syncReadingPosition` API takes a `TPPBook`, not a
    /// bookID — production callers always have the `TPPBook` in hand.
    typealias BookResolver = @Sendable (_ bookID: String) -> TPPBook?

    private let bookResolver: BookResolver

    init(bookResolver: @escaping BookResolver) {
        self.bookResolver = bookResolver
    }

    func post(_ snapshot: PositionSnapshot) async throws -> ServerPositionID {
        let selectorValue = String(data: snapshot.payload, encoding: .utf8) ?? ""
        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            TPPAnnotations.postReadingPosition(
                forBook: snapshot.bookID,
                selectorValue: selectorValue,
                motivation: .readingProgress
            ) { response in
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: response?.serverId ?? "")
            }
        }
    }

    func fetch(bookID: String) async throws -> PositionSnapshot? {
        guard let book = bookResolver(bookID) else { return nil }
        guard let bookmark = await TPPAnnotations.syncReadingPosition(
            ofBook: book,
            toURL: TPPAnnotations.annotationsURL
        ) as? TPPReadiumBookmark else {
            return nil
        }

        let locationString = bookmark.location
        return PositionSnapshot(
            bookID: bookID,
            format: .epubLocator,
            payload: Data(locationString.utf8),
            timestamp: Date(),
            device: bookmark.device ?? ""
        )
    }
}

/// Convenience factory mirroring the production wiring used by Reader2
/// callers. Holds the `TPPBook` in a closure so the adapter can satisfy
/// `fetch(bookID:)` without a registry lookup.
enum EPUBPositionWriterFactory {
    static func make(for book: TPPBook) -> PositionWriter {
        let adapter = EPUBPositionAdapter { requestedID in
            requestedID == book.identifier ? book : nil
        }
        return RemotePositionWriter(network: adapter)
    }
}
