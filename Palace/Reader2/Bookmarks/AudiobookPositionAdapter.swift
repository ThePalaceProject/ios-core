//
//  AudiobookPositionAdapter.swift
//  Palace
//
//  Bridge between `PalaceReadingPosition.PositionWriter` and the existing
//  audiobook `AnnotationsManager` surface. Lives in the Palace target so
//  the `PalaceReadingPosition` SPM stays free of `URLSession` /
//  `TPPNetworkExecutor` / `TPPAnnotations` dependencies.
//
//  The adapter is the "network seam" for audiobook position writes:
//  - `post(_:)` calls `AnnotationsManager.postListeningPosition(...)`
//  - `fetch(bookID:)` is currently unused on the audiobook write path
//    (`AudiobookBookmarkBusinessLogic` reads from `TPPBookRegistry` for
//    conflict resolution, not the server). Returning `nil` keeps the
//    `PositionWriter.load(for:)` contract honest until a remote-load
//    surface exists for audiobooks.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceReadingPosition
import PalaceBookRegistry

/// Network adapter for audiobook position writes. Wraps an
/// `AnnotationsManager` and translates `PositionSnapshot` calls into
/// `postListeningPosition` calls.
final class AudiobookPositionAdapter: PositionNetworkAdapter, @unchecked Sendable {
    private let annotations: AnnotationsManager

    init(annotations: AnnotationsManager) {
        self.annotations = annotations
    }

    func post(_ snapshot: PositionSnapshot) async throws -> ServerPositionID {
        guard let selectorValue = String(data: snapshot.payload, encoding: .utf8) else {
            throw PositionWriterError.malformedSnapshot
        }

        return try await withCheckedThrowingContinuation { continuation in
            annotations.postListeningPosition(
                forBook: snapshot.bookID,
                selectorValue: selectorValue
            ) { response in
                guard let serverID = response?.serverId, !serverID.isEmpty else {
                    continuation.resume(throwing: PositionWriterError.serverError(statusCode: -1, body: nil))
                    return
                }
                continuation.resume(returning: serverID)
            }
        }
    }

    func fetch(bookID: String) async throws -> PositionSnapshot? {
        // The audiobook write path resolves conflicts against the local
        // registry, not a fresh server fetch. Returning nil signals "no
        // remote-load implemented" without throwing — callers that don't
        // call `load(for:)` (the current audiobook path) are unaffected.
        nil
    }
}
