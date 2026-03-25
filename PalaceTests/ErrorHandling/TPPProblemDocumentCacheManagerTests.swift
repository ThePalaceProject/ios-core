//
//  TPPProblemDocumentCacheManagerTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TPPProblemDocumentCacheManagerTests: XCTestCase {

    private var cacheManager: TPPProblemDocumentCacheManager!

    override func setUp() {
        super.setUp()
        cacheManager = TPPProblemDocumentCacheManager()
    }

    // MARK: - Shared Instance

    func testSharedInstance_returnsSameObject() {
        let a = TPPProblemDocumentCacheManager.sharedInstance()
        let b = TPPProblemDocumentCacheManager.shared
        XCTAssertTrue(a === b, "sharedInstance() and shared should return the same object")
    }

    // MARK: - Cache Size Constant

    func testCacheSize_isFive() {
        XCTAssertEqual(TPPProblemDocumentCacheManager.CACHE_SIZE, 5)
    }

    // MARK: - Basic Cache/Retrieve

    func testCacheProblemDocument_andRetrieve() {
        let doc = TPPProblemDocument.fromDictionary([
            "title": "Loan Limit",
            "detail": "You have reached your loan limit."
        ])

        cacheManager.cacheProblemDocument(doc, key: "test-key-1")

        let retrieved = cacheManager.getLastCachedDoc("test-key-1")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.title, "Loan Limit")
    }

    func testGetLastCachedDoc_unknownKey_returnsNil() {
        let result = cacheManager.getLastCachedDoc("nonexistent-key-\(UUID().uuidString)")
        XCTAssertNil(result)
    }

    // MARK: - Multiple Documents Per Key

    func testCacheMultipleDocuments_lastEntryRetrievable() {
        let first = TPPProblemDocument.fromDictionary([
            "title": "First Error",
            "detail": "First detail"
        ])
        let second = TPPProblemDocument.fromDictionary([
            "title": "Second Error",
            "detail": "Second detail"
        ])

        cacheManager.cacheProblemDocument(first, key: "test-key-2")
        cacheManager.cacheProblemDocument(second, key: "test-key-2")

        let retrieved = cacheManager.getLastCachedDoc("test-key-2")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.title, "Second Error")
    }

    // MARK: - Clear

    func testClearCachedDoc_preventsRetrieval() {
        let doc = TPPProblemDocument.fromDictionary([
            "title": "To Be Cleared",
            "detail": "This will be removed"
        ])

        cacheManager.cacheProblemDocument(doc, key: "test-key-1")
        XCTAssertNotNil(cacheManager.getLastCachedDoc("test-key-1"))

        cacheManager.clearCachedDoc("test-key-1")
        XCTAssertNil(cacheManager.getLastCachedDoc("test-key-1"))
    }

    func testClearCachedDoc_nonexistentKey_doesNotCrash() {
        // Should not crash
        cacheManager.clearCachedDoc("nonexistent-key-\(UUID().uuidString)")
    }

    // MARK: - LRU Behavior

    func testCache_exceedingSize_evictsOldestEntry() {
        let key = "lru-test"

        for i in 0..<TPPProblemDocumentCacheManager.CACHE_SIZE {
            let doc = TPPProblemDocument.fromDictionary([
                "title": "Doc \(i)",
                "detail": "Detail \(i)"
            ])
            cacheManager.cacheProblemDocument(doc, key: key)
        }

        let overflow = TPPProblemDocument.fromDictionary([
            "title": "Overflow",
            "detail": "Should evict Doc 0"
        ])
        cacheManager.cacheProblemDocument(overflow, key: key)

        let retrieved = cacheManager.getLastCachedDoc(key)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.title, "Overflow")
    }

    func testClearThenReCache_works() {
        let key = "recache-test"
        let doc1 = TPPProblemDocument.fromDictionary(["title": "Before Clear"])
        cacheManager.cacheProblemDocument(doc1, key: key)
        cacheManager.clearCachedDoc(key)
        XCTAssertNil(cacheManager.getLastCachedDoc(key))

        let doc2 = TPPProblemDocument.fromDictionary(["title": "After Clear"])
        cacheManager.cacheProblemDocument(doc2, key: key)
        XCTAssertEqual(cacheManager.getLastCachedDoc(key)?.title, "After Clear")
    }

    // MARK: - Thread Safety

    func testConcurrentReadWrite_doesNotCrash() {
        let iterations = 20
        let group = DispatchGroup()

        for i in 0..<iterations {
            let key = "concurrent-\(i % 5)"
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let doc = TPPProblemDocument.fromDictionary(["title": "Doc \(i)"])
                self.cacheManager.cacheProblemDocument(doc, key: key)
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                _ = self.cacheManager.getLastCachedDoc(key)
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .background).async {
                self.cacheManager.clearCachedDoc(key)
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 10.0)
        XCTAssertEqual(result, .success, "All concurrent operations should complete")
    }

    func testConcurrentCacheAndClear_sameKey_doesNotCrash() {
        let key = "race-key"
        let group = DispatchGroup()

        for i in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                let doc = TPPProblemDocument.fromDictionary(["title": "Write \(i)"])
                self.cacheManager.cacheProblemDocument(doc, key: key)
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                self.cacheManager.clearCachedDoc(key)
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 10.0)
        XCTAssertEqual(result, .success, "All concurrent operations should complete")
    }

    // MARK: - Notification

    func testCacheProblemDocument_postsNotification() {
        let expectation = XCTNSNotificationExpectation(
            name: NSNotification.Name.TPPProblemDocumentWasCached
        )

        let doc = TPPProblemDocument.fromDictionary([
            "title": "Notification Test",
            "detail": "Should post notification"
        ])

        cacheManager.cacheProblemDocument(doc, key: "notif-key")

        wait(for: [expectation], timeout: 2.0)
    }
}
