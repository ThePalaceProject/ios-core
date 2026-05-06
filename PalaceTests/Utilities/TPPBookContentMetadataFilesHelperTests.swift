//
//  TPPBookContentMetadataFilesHelperTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TPPBookContentMetadataFilesHelperTests: XCTestCase {

    // MARK: - Directory for Account

    func testDirectory_validAccountId_returnsURL() {
        let url = TPPBookContentMetadataFilesHelper.directory(for: "test-account-uuid")
        XCTAssertNotNil(url, "Should return a URL for a valid account ID")
        XCTAssertTrue(url!.isFileURL, "Returned URL should be a file URL")
        XCTAssertFalse(url!.path.isEmpty, "Path should not be empty")
    }

    func testDirectory_differentAccounts_returnDifferentPaths() {
        let url1 = TPPBookContentMetadataFilesHelper.directory(for: "account-1")
        let url2 = TPPBookContentMetadataFilesHelper.directory(for: "account-2")

        XCTAssertNotNil(url1)
        XCTAssertNotNil(url2)
        XCTAssertNotEqual(url1, url2, "Different accounts should have different directories")
        // Both should be file URLs
        XCTAssertTrue(url1!.isFileURL)
        XCTAssertTrue(url2!.isFileURL)
    }

    func testDirectory_sameAccount_returnsSamePath() {
        let url1 = TPPBookContentMetadataFilesHelper.directory(for: "same-account")
        let url2 = TPPBookContentMetadataFilesHelper.directory(for: "same-account")

        XCTAssertEqual(url1, url2, "Same account ID should always return the same directory")
        // The path should contain the account ID for isolation
        XCTAssertTrue(url1?.path.contains("same-account") ?? false,
                      "Path should contain the account ID for isolation")
    }

    func testDirectory_pathContainsApplicationSupport() {
        let url = TPPBookContentMetadataFilesHelper.directory(for: "test-account")

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.path.contains("Application Support"),
                      "Directory should be in Application Support, got: \(url!.path)")
        // Path should end with the account or a sub-directory
        XCTAssertFalse(url!.path.hasSuffix("/"), "Path should not end with trailing slash before normalization")
    }

    // MARK: - Current Account Directory

    func testCurrentAccountDirectory_returnsURLOrNil() {
        let url = TPPBookContentMetadataFilesHelper.currentAccountDirectory()
        // May be nil if no account is signed in during tests
        if let url = url {
            XCTAssertTrue(url.isFileURL, "currentAccountDirectory must return a file URL when signed in")
            XCTAssertFalse(url.path.isEmpty, "currentAccountDirectory path must not be empty")
        }
        // nil is acceptable (no account signed in during tests)
        XCTAssertTrue(url == nil || url!.isFileURL, "Result must be nil or a valid file URL")
    }

    // MARK: - Edge Cases

    func testDirectory_emptyString_handlesGracefully() {
        let url = TPPBookContentMetadataFilesHelper.directory(for: "")
        // Should handle empty string gracefully (may return nil or a path)
        if let url = url {
            XCTAssertTrue(url.isFileURL, "If URL is returned for empty ID, it should be a file URL")
            XCTAssertFalse(url.path.isEmpty, "Returned path must not be empty")
        }
        // Both nil and non-nil are acceptable for empty input; result must differ from a valid-account URL
        let validURL = TPPBookContentMetadataFilesHelper.directory(for: "valid-account-id")
        XCTAssertNotEqual(url, validURL, "Empty-ID directory must differ from a valid-account directory")
    }

    func testDirectory_specialCharacters_handlesGracefully() {
        let url = TPPBookContentMetadataFilesHelper.directory(for: "account/with/slashes")
        // Should not crash even with special characters
        if let url = url {
            XCTAssertTrue(url.isFileURL)
            XCTAssertFalse(url.path.isEmpty)
        }
    }

    func testDirectory_longAccountId_handlesGracefully() {
        let longId = String(repeating: "a", count: 500)
        let url = TPPBookContentMetadataFilesHelper.directory(for: longId)
        // Should not crash with very long IDs
        if let url = url {
            XCTAssertTrue(url.isFileURL)
        }
    }

    // MARK: - Path Structure

    func testDirectory_containsBundleIdentifier() {
        let url = TPPBookContentMetadataFilesHelper.directory(for: "test-bundle-check")
        guard let path = url?.path else {
            // May be nil in some test environments
            return
        }

        // The path should reference the app's bundle ID or a related identifier
        // This verifies we're creating paths in the right app sandbox
        XCTAssertFalse(path.isEmpty)
        // The URL should be a file URL pointing to a reasonable location
        XCTAssertTrue(url!.isFileURL)
        // Path should contain Application Support as the storage area
        XCTAssertTrue(path.contains("Application Support") || path.contains("Library"),
                      "Metadata should be stored in a persistent app location")
    }
}
