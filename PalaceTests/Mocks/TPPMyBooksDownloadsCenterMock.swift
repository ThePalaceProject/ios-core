//
//  TPPMyBooksDownloadsCenterMock.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 11/3/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
@testable import Palace

// @unchecked Sendable: handed across isolation boundaries by Swift 6 tests
// (sending-value errors otherwise); accessed serially by the test flow.
class TPPMyBooksDownloadsCenterMock: TPPBookDownloadsDeleting, @unchecked Sendable {
    // Mutable state guarded by a single NSLock (matches TPPBookRegistryMock) so the
    // @unchecked Sendable conformance is sound under concurrent test access.
    private let lock = NSLock()
    private var _resetCalledLibraryIDs: [String?] = []

    /// Records the libraryID(s) passed to `reset` so tests can assert the
    /// downloads center was reset for the expected (active) library only.
    var resetCalledLibraryIDs: [String?] { lock.withLock { _resetCalledLibraryIDs } }

    func reset(_ libraryID: String!) {
        lock.withLock { _resetCalledLibraryIDs.append(libraryID) }
    }
}
