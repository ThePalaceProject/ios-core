//
//  PositionWriter.swift
//  PalaceReadingPosition
//
//  The canonical protocol for posting a reader's last-known position back
//  to the server. Audiobook, EPUB, and PDF call sites all funnel through
//  one implementation so that throttling, queuing, cancellation, and
//  background-task lifetime are decided in exactly one place.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// Server-side identifier returned when a position is successfully posted.
public typealias ServerPositionID = String

/// The unified reading-position writer.
///
/// Implementations are responsible for throttling, queue management, and
/// background-task lifetime. Conflict resolution between local and remote
/// positions is the **caller's** concern — `load(for:)` returns the raw
/// remote snapshot.
public protocol PositionWriter: Sendable {
    /// Persist a position snapshot.
    ///
    /// - Returns: A server-assigned identifier when the upload completes;
    ///            `nil` when the snapshot was throttled (queued, not yet
    ///            sent) or when the network adapter declined to send.
    /// - Throws: `PositionWriterError` on network/adapter failure.
    func save(_ snapshot: PositionSnapshot) async throws -> ServerPositionID?

    /// Load the most-recent position for a book from the writer's remote
    /// source.
    ///
    /// Implementations MUST NOT apply conflict resolution against any local
    /// position. Implementations MAY cache, but callers MUST treat the
    /// return value as a snapshot at time of fetch.
    ///
    /// - Returns: The remote snapshot, or `nil` if no remote position exists.
    /// - Throws: `PositionWriterError` on network/adapter failure.
    func load(for bookID: String) async throws -> PositionSnapshot?

    /// Cancel any pending writes for a book. Used at session teardown.
    ///
    /// Idempotent. Cancelling a book with no pending state is a no-op.
    /// Cancelling for one book does not affect any other book's queue.
    func cancel(for bookID: String) async
}
