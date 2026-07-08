//
//  PositionSyncService.swift
//  PalaceReadingPosition
//
//  Cross-format position sync service. Records reading positions locally
//  and offers cross-format sync between EPUB and audiobook formats.
//
//  This is the LOCAL-record sync layer. The network-write throttle layer
//  lives in `RemotePositionWriter`. They are separate concerns and ship
//  alongside each other in the same SPM.
//
//  Migrated from Palace/Platform/ on 2026-05-21 (Swarm 2, Deviation 4).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation

/// Actor-based cross-format position sync service.
/// Records reading positions and offers to sync between EPUB and audiobook formats.
public actor PositionSyncService: PositionSyncServiceProtocol {

    // MARK: - Singleton

    public static let shared = PositionSyncService()

    // MARK: - Storage

    private struct StorageData: Codable {
        var positions: [String: [String: ReadingPosition]] // bookID -> format.rawValue -> position
        var mappings: [String: CrossFormatMapping]          // bookID -> mapping
    }

    private var positions: [String: [String: ReadingPosition]] = [:]
    private var mappings: [String: CrossFormatMapping] = [:]
    private let storageKey = "Palace.Platform.positionSync"
    private let userDefaults: UserDefaults

    // MARK: - Combine

    private nonisolated(unsafe) let eventSubject = PassthroughSubject<PositionSyncEvent, Never>()

    public nonisolated var eventPublisher: AnyPublisher<PositionSyncEvent, Never> {
        eventSubject.eraseToAnyPublisher()
    }

    // MARK: - Init

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        // Load from storage synchronously in init (actor-isolated)
        if let data = userDefaults.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode(StorageData.self, from: data) {
            self.positions = stored.positions
            self.mappings = stored.mappings
        }
    }

    // MARK: - Position Recording

    public func recordPosition(_ position: ReadingPosition) async {
        let bookID = position.bookID
        let formatKey = position.format.rawValue

        if positions[bookID] == nil {
            positions[bookID] = [:]
        }
        positions[bookID]?[formatKey] = position

        persist()
        eventSubject.send(.positionRecorded(position))
    }

    // MARK: - Position Queries

    public func latestPosition(forBook bookID: String, format: ReadingFormat) async -> ReadingPosition? {
        positions[bookID]?[format.rawValue]
    }

    public func latestPositionAnyFormat(forBook bookID: String) async -> ReadingPosition? {
        guard let bookPositions = positions[bookID] else { return nil }
        return bookPositions.values.max(by: { $0.timestamp < $1.timestamp })
    }

    // MARK: - Cross-Format Sync

    public func checkForSyncOffer(bookID: String, openingFormat: ReadingFormat) async -> ReadingPosition? {
        guard let bookPositions = positions[bookID] else { return nil }

        // Find the most recent position in a different format
        let otherPositions = bookPositions
            .filter { $0.key != openingFormat.rawValue }
            .map { $0.value }
            .sorted { $0.timestamp > $1.timestamp }

        guard let otherPosition = otherPositions.first else { return nil }

        // Check if the other format's position is more recent than this format
        let currentFormatPosition = bookPositions[openingFormat.rawValue]
        if let current = currentFormatPosition, current.timestamp >= otherPosition.timestamp {
            return nil // Current format is already up to date
        }

        // Try to convert using mapping
        if let mapping = mappings[bookID] {
            let converted: ReadingPosition?
            switch openingFormat {
            case .epub:
                converted = mapping.toEpubPosition(from: otherPosition)
            case .audiobook:
                converted = mapping.toAudiobookPosition(from: otherPosition)
            case .pdf:
                converted = nil // PDF doesn't cross-format sync
            }

            if let convertedPosition = converted {
                eventSubject.send(.syncAvailable(from: otherPosition, to: convertedPosition))
                return convertedPosition
            }
        }

        // No mapping available, but still report the other position exists
        // The caller can show a generic "you were reading the audiobook" message
        eventSubject.send(.syncAvailable(from: otherPosition, to: otherPosition))
        return otherPosition
    }

    // MARK: - Mappings

    public func setMapping(_ mapping: CrossFormatMapping) async {
        mappings[mapping.bookID] = mapping
        persist()
    }

    public func mapping(forBook bookID: String) async -> CrossFormatMapping? {
        mappings[bookID]
    }

    // MARK: - Cleanup

    public func clearPositions(forBook bookID: String) async {
        positions.removeValue(forKey: bookID)
        mappings.removeValue(forKey: bookID)
        persist()
    }

    public func clearAll() async {
        positions.removeAll()
        mappings.removeAll()
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        let data = StorageData(positions: positions, mappings: mappings)
        if let encoded = try? JSONEncoder().encode(data) {
            userDefaults.set(encoded, forKey: storageKey)
        }
    }
}
