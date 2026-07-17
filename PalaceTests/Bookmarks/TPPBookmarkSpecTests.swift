//
//  TPPBookmarkSpecTests.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 3/22/21.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

import XCTest
@testable import Palace

// TODO: SIMPLY-3645
@MainActor
class TPPBookmarkSpecTests: XCTestCase {

    override func setUpWithError() throws {
    }

    override func tearDownWithError() throws {
    }

    func testBookmarkMotivationKeyword() throws {
        XCTAssert(
            TPPBookmarkSpec.Motivation.bookmark.rawValue
                .contains(TPPBookmarkSpec.Motivation.bookmarkingKeyword)
        )
        // The bookmark raw value should be a well-formed URI
        XCTAssertFalse(TPPBookmarkSpec.Motivation.bookmark.rawValue.isEmpty,
                       "Bookmark motivation raw value should not be empty")
        // The bookmarking keyword itself should not be empty
        XCTAssertFalse(TPPBookmarkSpec.Motivation.bookmarkingKeyword.isEmpty,
                       "Bookmarking keyword should not be empty")
        // The keyword should be a substring of the full motivation URI
        let fullMotivation = TPPBookmarkSpec.Motivation.bookmark.rawValue
        let keyword = TPPBookmarkSpec.Motivation.bookmarkingKeyword
        let range = fullMotivation.range(of: keyword)
        XCTAssertNotNil(range, "Bookmarking keyword should be found within the motivation URI")
    }
}
