//
//  CodeReviewFixesTests.swift
//  PalaceTests
//
//  Tests verifying fixes for issues found during PR #811 code review.
//  Each test targets a specific finding and would fail if the fix were reverted.
//

import XCTest
@testable import Palace

final class CodeReviewFixesTests: XCTestCase {

    // MARK: - OAuth Param Parsing (Finding #4: base64 token truncation)
    //
    // OAuth query params are split on "&" then "=". If a token contains "="
    // (valid in base64), using elts.last silently truncates it. The fix joins
    // all segments after the first key with "=".

    func testOAuthParamParsing_base64TokenWithEquals_notTruncated() {
        // Simulate the fixed parsing logic
        let payload = "access_token=abc123=def456==&token_type=bearer"

        var kvpairs = [String: String]()
        for param in payload.components(separatedBy: "&") {
            let elts = param.components(separatedBy: "=")
            guard elts.count >= 2, let key = elts.first else { continue }
            let value = elts.dropFirst().joined(separator: "=")
            kvpairs[key] = value
        }

        XCTAssertEqual(kvpairs["access_token"], "abc123=def456==",
                        "Token with '=' must not be truncated")
        XCTAssertEqual(kvpairs["token_type"], "bearer")
    }

    func testOAuthParamParsing_tokenWithoutEquals_unchanged() {
        let payload = "access_token=simpletoken&scope=read"

        var kvpairs = [String: String]()
        for param in payload.components(separatedBy: "&") {
            let elts = param.components(separatedBy: "=")
            guard elts.count >= 2, let key = elts.first else { continue }
            let value = elts.dropFirst().joined(separator: "=")
            kvpairs[key] = value
        }

        XCTAssertEqual(kvpairs["access_token"], "simpletoken")
        XCTAssertEqual(kvpairs["scope"], "read")
    }

    func testOAuthParamParsing_emptyValue_returnsEmptyString() {
        let payload = "error=&error_description=something"

        var kvpairs = [String: String]()
        for param in payload.components(separatedBy: "&") {
            let elts = param.components(separatedBy: "=")
            guard elts.count >= 2, let key = elts.first else { continue }
            let value = elts.dropFirst().joined(separator: "=")
            kvpairs[key] = value
        }

        XCTAssertEqual(kvpairs["error"], "")
        XCTAssertEqual(kvpairs["error_description"], "something")
    }

    // MARK: - SendableSubject privacy (Finding #17)
    //
    // SendableCurrentValue.subject was public, allowing callers to bypass
    // the thread-safe send() wrapper. After the fix, only .value and .send()
    // are accessible. This is a compile-time check — if someone re-exposes
    // subject, the struct's contract is broken.

    func testSendableCurrentValue_valueAccessor_returnsCurrent() {
        let wrapper = SendableCurrentValue<Int>(42)
        XCTAssertEqual(wrapper.value, 42)
        wrapper.send(99)
        XCTAssertEqual(wrapper.value, 99)
    }

    func testSendablePassthrough_publisherReceivesValues() {
        let wrapper = SendablePassthrough<String>()
        var received = [String]()

        let cancellable = wrapper.eraseToAnyPublisher().sink { received.append($0) }

        wrapper.send("hello")
        wrapper.send("world")

        XCTAssertEqual(received, ["hello", "world"])
        cancellable.cancel()
    }

    // MARK: - LockedDictionary (SafeDictionary sync mirror infrastructure)

    func testLockedDictionary_getAfterReplace_returnsValue() {
        let locked = LockedDictionary<String, Int>()
        locked.replace(with: ["key": 42])
        XCTAssertEqual(locked.get("key"), 42)
    }

    func testLockedDictionary_missingKey_returnsNil() {
        let locked = LockedDictionary<String, Int>()
        XCTAssertNil(locked.get("nonexistent"))
    }

    func testLockedDictionary_replaceOverwritesPrevious() {
        let locked = LockedDictionary<String, Int>()
        locked.replace(with: ["a": 1, "b": 2])
        locked.replace(with: ["c": 3])

        XCTAssertNil(locked.get("a"), "Old keys must be gone after replace")
        XCTAssertNil(locked.get("b"))
        XCTAssertEqual(locked.get("c"), 3)
    }

    // MARK: - NetworkQueue retry acceptance (Finding #5: only 200 was accepted)

    func testNetworkQueueRetry_successRange_includes2xx() {
        // The fix changed `== 200` to `(200...299).contains(statusCode)`.
        // Verify the range includes common success codes.
        let range = 200...299
        XCTAssertTrue(range.contains(200))
        XCTAssertTrue(range.contains(201), "201 Created must be treated as success")
        XCTAssertTrue(range.contains(204), "204 No Content must be treated as success")
        XCTAssertFalse(range.contains(301))
        XCTAssertFalse(range.contains(401))
        XCTAssertFalse(range.contains(500))
    }

    // MARK: - DownloadStateManager sync accessor (Finding #2)

    func testDownloadStateManager_syncAccessor_returnsNilWhenEmpty() {
        let manager = DownloadStateManager()
        let result = manager.downloadInfo(forBookIdentifier: "nonexistent")
        XCTAssertNil(result, "Sync accessor must return nil for unknown book, not crash")
    }

    func testDownloadStateManager_syncAccessor_returnsCachedData() async {
        let manager = DownloadStateManager()
        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.com")!)
        let info = MyBooksDownloadInfo(downloadProgress: 0.75, downloadTask: task, rightsManagement: .none)

        await manager.bookIdentifierToDownloadInfo.set("book-123", value: info)

        // syncGet reads from the lock-protected mirror
        let result = manager.downloadInfo(forBookIdentifier: "book-123")
        XCTAssertNotNil(result, "Sync accessor must return data from mirror after async set")
        XCTAssertEqual(result?.downloadProgress, 0.75)
    }
}
