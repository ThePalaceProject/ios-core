//
//  TPPMyBooksDownloadsCenterMock.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 11/3/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
@testable import Palace

/// `@unchecked Sendable`: the sole mutable state (`_resetCalledLibraryIDs`) is
/// guarded by `lock`, so instances can cross into the @MainActor SUT safely
/// (Swift 6). Mirrors TPPBookRegistryMock.
final class TPPMyBooksDownloadsCenterMock: TPPBookDownloadsDeleting, @unchecked Sendable {
    private let lock = NSLock()

    /// Records the libraryID(s) passed to `reset` so tests can assert the
    /// downloads center was reset for the expected (active) library only.
    private var _resetCalledLibraryIDs: [String?] = []
    private(set) var resetCalledLibraryIDs: [String?] {
        get { lock.withLock { _resetCalledLibraryIDs } }
        set { lock.withLock { _resetCalledLibraryIDs = newValue } }
    }

    func reset(_ libraryID: String!) {
        lock.withLock { _resetCalledLibraryIDs.append(libraryID) }
    }
}
