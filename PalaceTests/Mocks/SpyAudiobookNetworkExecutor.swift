//
//  SpyAudiobookNetworkExecutor.swift
//  PalaceTests
//
//  Thread-safe spy that records POST(_:useTokenIfAvailable:) calls so
//  AudiobookPlaytimesLifecycleTests can assert the cross-account scope
//  guard prevents foreign-host uploads. Distinct from
//  MockNetworkExecutorForSync (private in AudiobookDataManagerSyncTests):
//  this one is a shared Mock targeting the playtimes-lifecycle scope guard
//  introduced by swarm_162a3219 / Bug B, with a focus on URL-level
//  observation rather than response stubbing.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation
@testable import Palace

/// Records every POST that hits the executor. Default behavior is to
/// respond 200 with a success-shaped response body matching the entry
/// IDs in the request body — that's enough for the lifecycle tests to
/// drive the queue through successful sync and verify post-switch
/// uploads do NOT recur.
final class SpyAudiobookNetworkExecutor: TPPNetworkExecutor {

    struct RecordedCall {
        let url: URL
        let body: Data?
    }

    private let lock = NSLock()
    private var _calls: [RecordedCall] = []
    /// Counter incremented after the completion handler returns, so tests
    /// can wait until AudiobookDataManager's response processing has
    /// finished — not just until the request was dispatched.
    private var _completionsReturned: Int = 0
    /// When true, every POST responds 200 with a success-shaped
    /// `responses[]` body derived from the request body's `timeEntries[].id`
    /// values, so AudiobookDataManager's `removeSynchronizedEntries(ids:)`
    /// runs and the queue empties. When false, the executor still records
    /// the call but does not invoke the completion — useful for "in-flight"
    /// scenarios where the test wants to fire `.TPPCurrentAccountDidChange`
    /// before the response lands.
    var autoRespondSuccess: Bool = true

    var calls: [RecordedCall] {
        lock.withLock { _calls }
    }

    var completionsReturned: Int {
        lock.withLock { _completionsReturned }
    }

    var postedURLs: [URL] {
        lock.withLock { _calls.map { $0.url } }
    }

    func reset() {
        lock.withLock {
            _calls.removeAll()
            _completionsReturned = 0
        }
    }

    convenience init() {
        self.init(cachingStrategy: .ephemeral)
    }

    override func POST(_ request: URLRequest,
                       useTokenIfAvailable: Bool,
                       completion: ((_ result: Data?, _ response: URLResponse?, _ error: Error?) -> Void)?) -> URLSessionDataTask? {
        let body = request.httpBody
        lock.withLock {
            _calls.append(RecordedCall(url: request.url!, body: body))
        }

        guard autoRespondSuccess, let url = request.url else {
            // Don't fire completion — caller wants to inspect mid-flight state.
            return nil
        }

        // Derive success-shaped response from the request body's entry IDs
        // so AudiobookDataManager.removeSynchronizedEntries(ids:) clears
        // the queue exactly as production would on a 200 OK.
        let responseBody = SpyAudiobookNetworkExecutor.successResponseData(forRequestBody: body)
        let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "1.1",
            headerFields: ["Content-Type": "application/json"]
        )
        DispatchQueue.global().async { [weak self] in
            completion?(responseBody, httpResponse, nil)
            self?.lock.withLock { self?._completionsReturned += 1 }
        }
        return nil
    }

    /// Builds a `ResponseData`-shaped success body from the entries in the
    /// request body. AudiobookDataManager parses this response and removes
    /// every entry whose id appears with status < 400 — letting tests use
    /// queue-emptiness as the "sync ran" signal.
    private static func successResponseData(forRequestBody body: Data?) -> Data {
        guard let body else {
            return Data("{\"responses\": []}".utf8)
        }
        guard let raw = try? JSONSerialization.jsonObject(with: body),
              let json = raw as? [String: Any],
              let entries = json["timeEntries"] as? [[String: Any]] else {
            return Data("{\"responses\": []}".utf8)
        }
        let ids = entries.compactMap { $0["id"] as? String }
        let lines = ids.map { "{\"status\": 200, \"message\": \"OK\", \"id\": \"\($0)\"}" }
        return Data("{\"responses\": [\(lines.joined(separator: ","))]}".utf8)
    }
}
