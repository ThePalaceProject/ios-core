//
//  PositionSyncRecord.swift
//  PalaceReadingPosition
//
//  A record of a reading position for sync purposes.
//
//  Migrated from Palace/Platform/ on 2026-05-21 (Swarm 2, Deviation 4).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// A sync record wrapping a reading position with metadata about its source.
public struct PositionSyncRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let position: ReadingPosition
    public let sourceDeviceID: String
    public let recordedAt: Date

    public init(position: ReadingPosition, sourceDeviceID: String? = nil) {
        self.id = UUID()
        self.position = position
        self.sourceDeviceID = sourceDeviceID ?? position.deviceID
        self.recordedAt = Date()
    }

    /// Whether this record is from the current device.
    public var isFromCurrentDevice: Bool {
        sourceDeviceID == ReadingPosition.currentDeviceID
    }
}
