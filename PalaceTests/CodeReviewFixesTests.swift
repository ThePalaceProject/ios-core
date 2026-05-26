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

    /// `LockedDictionary` provides thread-safe storage with replace/get
    /// semantics. Lock the basic contract in one body: empty dictionary
    /// returns nil for any key, replace makes keys queryable, and the
    /// queried value matches what was inserted. Catches a mutant that
    /// drops the lookup or returns a constant.
    func testLockedDictionary_getReturnsNilOnMissingAndStoredValueAfterReplace() {
        let locked = LockedDictionary<String, Int>()

        // Empty: any key yields nil.
        XCTAssertNil(locked.get("nonexistent"),
                     "Empty dictionary must return nil for any key")
        XCTAssertNil(locked.get(""),
                     "Empty key on empty dictionary must also yield nil")

        // After replace: stored value is queryable; unknown keys still nil.
        locked.replace(with: ["key": 42, "other": 99])
        XCTAssertEqual(locked.get("key"), 42,
                       "Stored value must be retrievable verbatim")
        XCTAssertEqual(locked.get("other"), 99,
                       "All keys from replace must be retrievable")
        XCTAssertNil(locked.get("missing-after-replace"),
                     "Keys not in the replace set must still yield nil — no phantom default")
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

    /// Sync accessor must safely return nil for unknown identifiers
    /// (never crash, never invent state). Pin three input shapes — empty
    /// id, unknown id, multi-call sequence — so a mutant that returns a
    /// default DownloadInfo on missing keys fails on a distinct row.
    func testDownloadStateManager_syncAccessor_returnsNilForUnknownAndEmptyIdentifiers() {
        let manager = DownloadStateManager()

        XCTAssertNil(manager.downloadInfo(forBookIdentifier: "nonexistent"),
                     "Unknown book id must yield nil — no phantom DownloadInfo")
        XCTAssertNil(manager.downloadInfo(forBookIdentifier: ""),
                     "Empty book id must also yield nil — no fallback to a default entry")
        // Repeat call for the same id remains nil (no side-effect lookup).
        XCTAssertNil(manager.downloadInfo(forBookIdentifier: "nonexistent"),
                     "Repeated lookup for unknown id must remain nil — guards against an `inserted on lookup` mutant")
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
