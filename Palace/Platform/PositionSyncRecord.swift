//
//  PositionSyncRecord.swift
//  Palace
//
//  A record of a reading position for sync purposes.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// A sync record wrapping a reading position with metadata about its source.
struct PositionSyncRecord: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let position: ReadingPosition
    let sourceDeviceID: String
    let recordedAt: Date

    init(position: ReadingPosition, sourceDeviceID: String? = nil) {
        self.id = UUID()
        self.position = position
        self.sourceDeviceID = sourceDeviceID ?? position.deviceID
        self.recordedAt = Date()
    }

    /// Whether this record is from the current device.
    var isFromCurrentDevice: Bool {
        sourceDeviceID == ReadingPosition.currentDeviceID
    }
}
