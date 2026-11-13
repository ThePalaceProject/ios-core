//
//  OfflineAction+Testing.swift
//  PalaceTests
//
//  Tests that do not exercise library scoping build actions under one fixed
//  library and give their queue the same library as current.
//

@testable import Palace

extension OfflineAction {
    static let testLibraryID = "offline-test-library"

    init(type: OfflineActionType, bookID: String, bookTitle: String, maxRetries: Int = 3) {
        self.init(type: type, bookID: bookID, bookTitle: bookTitle,
                  libraryID: Self.testLibraryID, maxRetries: maxRetries)
    }
}
