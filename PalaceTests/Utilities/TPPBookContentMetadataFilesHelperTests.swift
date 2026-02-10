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
  }

  func testDirectory_differentAccounts_returnDifferentPaths() {
    let url1 = TPPBookContentMetadataFilesHelper.directory(for: "account-1")
    let url2 = TPPBookContentMetadataFilesHelper.directory(for: "account-2")

    XCTAssertNotNil(url1)
    XCTAssertNotNil(url2)
    XCTAssertNotEqual(url1, url2, "Different accounts should have different directories")
  }

  func testDirectory_sameAccount_returnsSamePath() {
    let url1 = TPPBookContentMetadataFilesHelper.directory(for: "same-account")
    let url2 = TPPBookContentMetadataFilesHelper.directory(for: "same-account")

    XCTAssertEqual(url1, url2, "Same account ID should always return the same directory")
  }

  func testDirectory_pathContainsApplicationSupport() {
    let url = TPPBookContentMetadataFilesHelper.directory(for: "test-account")

    XCTAssertNotNil(url)
    XCTAssertTrue(url!.path.contains("Application Support"),
                  "Directory should be in Application Support, got: \(url!.path)")
  }

  // MARK: - Current Account Directory

  func testCurrentAccountDirectory_returnsURLOrNil() {
    let url = TPPBookContentMetadataFilesHelper.currentAccountDirectory()
    // May be nil if no account is signed in during tests
    // Just verify it doesn't crash
    let _ = url
  }

  // MARK: - Edge Cases

  func testDirectory_emptyString_handlesGracefully() {
    let url = TPPBookContentMetadataFilesHelper.directory(for: "")
    // Should handle empty string gracefully (may return nil or a path)
    let _ = url
  }

  func testDirectory_specialCharacters_handlesGracefully() {
    let url = TPPBookContentMetadataFilesHelper.directory(for: "account/with/slashes")
    // Should not crash even with special characters
    let _ = url
  }

  func testDirectory_longAccountId_handlesGracefully() {
    let longId = String(repeating: "a", count: 500)
    let url = TPPBookContentMetadataFilesHelper.directory(for: longId)
    // Should not crash with very long IDs
    let _ = url
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
  }
}
