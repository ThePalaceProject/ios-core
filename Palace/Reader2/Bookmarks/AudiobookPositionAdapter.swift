//
//  AudiobookPositionAdapter.swift
//  Palace
//
//  Bridge between `PalaceReadingPosition.PositionWriter` and the existing
//  audiobook `AnnotationsManager` surface. Lives in the Palace target so
//  the `PalaceReadingPosition` SPM stays free of `URLSession` /
//  `TPPNetworkExecutor` / `TPPAnnotations` dependencies.
//
//  `fetch(bookID:)` returns nil: audiobook conflict resolution reads the
//  local registry, not the server.
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
        // No remote load for audiobooks; see the file header.
        nil
    }
}
