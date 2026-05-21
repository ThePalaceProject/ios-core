//
//  PositionNetworkAdapter.swift
//  PalaceReadingPosition
//
//  Network seam — concrete implementations live in the Palace target so
//  the SPM package stays free of `URLSession`/`TPPNetworkExecutor`
//  dependencies.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// The network seam between `PositionWriter` and the rest of the app.
///
/// Implementations translate `PositionSnapshot` into whatever wire format
/// the server expects (Open Annotations payload, custom JSON, etc.) and
/// map transport errors into `PositionWriterError`.
public protocol PositionNetworkAdapter: AnyObject, Sendable {
    /// POST the snapshot. Returns the server-assigned identifier on
    /// success.
    func post(_ snapshot: PositionSnapshot) async throws -> ServerPositionID

    /// GET the most-recent stored snapshot for a book. Returns `nil` if
    /// the server has nothing stored.
    func fetch(bookID: String) async throws -> PositionSnapshot?
}
