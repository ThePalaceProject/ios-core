//
//  TPPMyBooksDownloadsCenterMock.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 11/3/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
@testable import Palace

class TPPMyBooksDownloadsCenterMock: TPPBookDownloadsDeleting {
    /// Records the libraryID(s) passed to `reset` so tests can assert the
    /// downloads center was reset for the expected (active) library only.
    private(set) var resetCalledLibraryIDs: [String?] = []

    func reset(_ libraryID: String!) {
        resetCalledLibraryIDs.append(libraryID)
    }
}
