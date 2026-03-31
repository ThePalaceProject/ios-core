//
//  PositionSyncServiceProtocol.swift
//  Palace
//
//  Protocol for cross-format position sync service.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation

/// Events published by the position sync service.
enum PositionSyncEvent: Sendable {
    /// A new position was recorded.
    case positionRecorded(ReadingPosition)
    /// A cross-format sync opportunity was detected.
    case syncAvailable(from: ReadingPosition, to: ReadingPosition)
}

/// Protocol for the cross-format position sync service.
protocol PositionSyncServiceProtocol: Sendable {
    /// Publisher for position sync events.
    var eventPublisher: AnyPublisher<PositionSyncEvent, Never> { get }

    /// Record a position update from a reader or audiobook player.
    func recordPosition(_ position: ReadingPosition) async

    /// Get the latest position for a book in a specific format.
    func latestPosition(forBook bookID: String, format: ReadingFormat) async -> ReadingPosition?

    /// Get the latest position for a book across all formats.
    func latestPositionAnyFormat(forBook bookID: String) async -> ReadingPosition?

    /// Check if a cross-format sync is available for a book being opened in a given format.
    /// Returns the position in the other format if available and more recent.
    func checkForSyncOffer(bookID: String, openingFormat: ReadingFormat) async -> ReadingPosition?

    /// Set a chapter mapping for a book (enables cross-format sync).
    func setMapping(_ mapping: CrossFormatMapping) async

    /// Get the chapter mapping for a book.
    func mapping(forBook bookID: String) async -> CrossFormatMapping?

    /// Clear all positions for a book.
    func clearPositions(forBook bookID: String) async

    /// Clear all stored data.
    func clearAll() async
}
