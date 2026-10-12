//
//  URLSessionNetworkClientCancellationTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceNetwork
@testable import Palace

/// A URLProtocol that accepts the request and then never responds, modelling a
/// wedged connection.
private final class HangingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { /* intentionally never completes */ }
    override func stopLoading() { /* no-op */ }
}

/// Cancelling the Task awaiting `URLSessionNetworkClient.send` must free the
/// request promptly; a held request keeps a connection-pool slot and can starve
/// other feed fetches to the same host (#1116).
@MainActor
final class URLSessionNetworkClientCancellationTests: XCTestCase {

    func testSend_cancellingTask_freesRequestPromptly() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HangingURLProtocol.self]
        let executor = TPPNetworkExecutor(cachingStrategy: .ephemeral, sessionConfiguration: config)
        let client = URLSessionNetworkClient(executor: executor)
        // Built inside the Task: NetworkRequest is not Sendable, so capturing one
        // from the main actor and passing it to the nonisolated send is rejected.
        let sendTask = Task<Void, Error> {
            _ = try await client.send(NetworkRequest(method: .GET, url: URL(string: "https://example.com/hang")!))
        }

        // Let the hanging request actually start before we cancel.
        try? await Task.sleep(nanoseconds: 300_000_000)

        let cancelledAt = DispatchTime.now()
        sendTask.cancel()

        do {
            _ = try await sendTask.value
            XCTFail("Cancelled send must throw rather than return a response")
        } catch {
            let elapsedMs = (DispatchTime.now().uptimeNanoseconds - cancelledAt.uptimeNanoseconds) / 1_000_000
            XCTAssertLessThan(elapsedMs, 3_000,
                              "Cancellation must free the request promptly via task cancellation, " +
                              "not wait for the URLSession timeout (took \(elapsedMs)ms)")
        }
    }
}
