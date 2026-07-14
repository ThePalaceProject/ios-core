//
//  TPPNetworkResponderSizeLimitTests.swift
//  PalaceTests
//
//  PP-4769 Issue #2 (crash 898c0776 — EXC_BREAKPOINT inside `__DataStorage.init`
//  bridging a giant response body NSData→Data under iPad memory pressure).
//
//  These tests drive the SHARED data-task completion path
//  (`TPPNetworkExecutor` → `TPPNetworkResponder`) through `HTTPStubURLProtocol`
//  and prove the bounded response-size guard:
//   • a body over `maxResponseBodyBytes` fails cleanly with
//     `TPPErrorCode.responseTooLarge` and does NOT surface the buffered body,
//   • a normal-size body still succeeds unchanged (no false positive),
//   • the cap boundary is inclusive-safe (a body exactly at the cap succeeds;
//     one byte over fails).
//
//  The cap is lowered on the executor's responder for the test so the oversize
//  path is driven deterministically without allocating a real 100 MB body —
//  `maxResponseBodyBytes` is a documented internal test seam (mirrors
//  `TPPNetworkExecutor.tokenRefreshWatchdogSeconds`).
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TPPNetworkResponderSizeLimitTests: XCTestCase {

    private var executor: TPPNetworkExecutor!
    private var libraryAccount: TPPLibraryAccountMock!

    /// Small cap so the oversize path is reachable with a few-KB body instead
    /// of the 100 MB production ceiling.
    private let testCap: Int64 = 4 * 1024 // 4 KB

    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.reset()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        libraryAccount = TPPLibraryAccountMock()
        executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            accountsManager: libraryAccount,
            delegateQueue: nil
        )
        // Lower the responder's ceiling for deterministic exercise.
        executor.responder.maxResponseBodyBytes = testCap
    }

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        executor = nil
        libraryAccount = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func body(ofSize count: Int) -> Data {
        Data(repeating: 0x41, count: count) // 'A' * count
    }

    // MARK: - Oversize → clean failure

    /// A response whose body exceeds the cap must complete with the specific
    /// `responseTooLarge` error and MUST NOT deliver the buffered body. This is
    /// the guard that replaces the OOM crash with a clean failure.
    func testResponse_overCap_failsWithResponseTooLarge_andDropsBody() {
        // 1 KB over the 4 KB cap.
        let oversize = body(ofSize: Int(testCap) + 1024)
        HTTPStubURLProtocol.register { _ in
            .init(statusCode: 200, headers: nil, body: oversize)
        }

        let done = expectation(description: "oversize completes")
        var gotData: Data?
        var gotError: NSError?

        executor.GET(
            URL(string: "https://api.example.com/huge")!,
            cachePolicy: .useProtocolCachePolicy,
            useTokenIfAvailable: false
        ) { data, _, error in
            gotData = data
            gotError = error as NSError?
            done.fulfill()
        }

        wait(for: [done], timeout: 10.0)

        XCTAssertNil(gotData, "oversize response must NOT deliver a (partial) body")
        XCTAssertNotNil(gotError, "oversize response must fail")
        XCTAssertEqual(gotError?.code, TPPErrorCode.responseTooLarge.rawValue,
                       "oversize must fail specifically with responseTooLarge, not a generic cancelled/other error")
    }

    // MARK: - Up-front Content-Length guard

    /// When the server DECLARES an oversize `Content-Length` up front, the
    /// response must be refused in `didReceive response:` before the body is
    /// buffered — again failing with `responseTooLarge`. Declaring a huge
    /// Content-Length header (with only a tiny actual body) drives
    /// `expectedContentLength` over the cap so the up-front branch fires,
    /// distinct from the running-total branch covered above.
    func testResponse_declaredContentLengthOverCap_refusedUpFront() {
        let declared = testCap + 1 // one byte over the cap
        HTTPStubURLProtocol.register { _ in
            .init(statusCode: 200,
                  headers: ["Content-Length": "\(declared)"],
                  body: "tiny".data(using: .utf8))
        }

        let done = expectation(description: "declared-oversize completes")
        var gotData: Data?
        var gotError: NSError?

        executor.GET(
            URL(string: "https://api.example.com/declared-huge")!,
            cachePolicy: .useProtocolCachePolicy,
            useTokenIfAvailable: false
        ) { data, _, error in
            gotData = data
            gotError = error as NSError?
            done.fulfill()
        }

        wait(for: [done], timeout: 10.0)

        XCTAssertNil(gotData, "declared-oversize response must NOT deliver a body")
        XCTAssertEqual(gotError?.code, TPPErrorCode.responseTooLarge.rawValue,
                       "a declared oversize Content-Length must be refused up front as responseTooLarge")
    }

    // MARK: - Normal size → unchanged success

    /// A response comfortably under the cap must succeed and return its exact
    /// body — proving the guard does not regress the overwhelmingly-common
    /// legitimate path.
    func testResponse_underCap_succeedsWithFullBody() {
        let payload = body(ofSize: Int(testCap) / 2) // 2 KB, well under cap
        HTTPStubURLProtocol.register { _ in
            .init(statusCode: 200, headers: nil, body: payload)
        }

        let done = expectation(description: "normal completes")
        var gotData: Data?
        var gotError: Error?

        executor.GET(
            URL(string: "https://api.example.com/normal")!,
            cachePolicy: .useProtocolCachePolicy,
            useTokenIfAvailable: false
        ) { data, _, error in
            gotData = data
            gotError = error
            done.fulfill()
        }

        wait(for: [done], timeout: 10.0)

        XCTAssertNil(gotError, "a normal-size response must not be refused")
        XCTAssertEqual(gotData, payload, "a normal-size response must return its exact body unchanged")
    }

    // MARK: - Boundary — at cap succeeds, one over fails

    /// A body exactly AT the cap must still succeed (the guard fires only when
    /// the projected size STRICTLY EXCEEDS the cap). Kills an off-by-one mutant
    /// that would flip `>` to `>=` and start refusing legitimate at-limit
    /// responses.
    func testResponse_exactlyAtCap_succeeds() {
        let atCap = body(ofSize: Int(testCap))
        HTTPStubURLProtocol.register { _ in
            .init(statusCode: 200, headers: nil, body: atCap)
        }

        let done = expectation(description: "at-cap completes")
        var gotData: Data?
        var gotError: Error?

        executor.GET(
            URL(string: "https://api.example.com/atcap")!,
            cachePolicy: .useProtocolCachePolicy,
            useTokenIfAvailable: false
        ) { data, _, error in
            gotData = data
            gotError = error
            done.fulfill()
        }

        wait(for: [done], timeout: 10.0)

        XCTAssertNil(gotError, "a body exactly at the cap must NOT be refused")
        XCTAssertEqual(gotData?.count, Int(testCap), "at-cap body must be delivered in full")
    }

    /// A response that DECLARES a Content-Length exactly AT the cap must still
    /// pass the up-front `didReceive response:` guard (which fires only when the
    /// declared length STRICTLY EXCEEDS the cap). This closes the boundary that
    /// `testResponse_exactlyAtCap_succeeds` does NOT reach: that test sends no
    /// Content-Length header, so it only exercises the running-total branch —
    /// leaving the declared-length branch's off-by-one (`declared > cap` →
    /// `declared >= cap`) unpinned. Here the declared length equals the cap, so
    /// the original allows it (success) while the `>=` mutant refuses it.
    func testResponse_declaredContentLengthExactlyAtCap_succeeds() {
        let declared = testCap // exactly at the cap
        let atCap = body(ofSize: Int(testCap))
        HTTPStubURLProtocol.register { _ in
            .init(statusCode: 200,
                  headers: ["Content-Length": "\(declared)"],
                  body: atCap)
        }

        let done = expectation(description: "declared-at-cap completes")
        var gotData: Data?
        var gotError: Error?

        executor.GET(
            URL(string: "https://api.example.com/declared-atcap")!,
            cachePolicy: .useProtocolCachePolicy,
            useTokenIfAvailable: false
        ) { data, _, error in
            gotData = data
            gotError = error
            done.fulfill()
        }

        wait(for: [done], timeout: 10.0)

        XCTAssertNil(gotError, "a response declaring Content-Length exactly at the cap must NOT be refused up front")
        XCTAssertEqual(gotData?.count, Int(testCap), "declared-at-cap body must be delivered in full")
    }
}
