//
//  OfflineQueueSpy.swift
//  PalaceTests
//
//  Records what `TPPAnnotations` hands to the offline retry queue.
//
//  PP-4987 made `.queuedForRetry` reachable in production, which turned "the
//  write reached the queue" into a load-bearing claim: PP-4965 removes the
//  error report for a queued write on exactly that basis. Before this spy the
//  claim was unassertable — `addToOfflineQueue` reached
//  `AppContainer.production().networkQueue` directly, so tests could only
//  prove that nothing was REPORTED, never that anything was STORED.
//
//  It also keeps the cross-device suite out of the app's real `simplified.db`:
//  once the branch went live those tests began writing durable rows a later
//  reachability event could replay.
//

import Foundation
@testable import Palace

final class OfflineQueueSpy: AnnotationOfflineQueueing {

    struct Enqueued {
        let libraryID: String
        let updateID: String?
        let url: URL
        let method: HTTPMethodType
        let parameters: Data?
        let headers: [String: String]?

        /// The POSTed annotation body, decoded — so tests can assert WHICH
        /// write was stored rather than merely that one was.
        var body: [String: Any]? {
            guard let parameters else { return nil }
            return try? JSONSerialization.jsonObject(with: parameters) as? [String: Any]
        }
    }

    private let lock = NSLock()
    private var _enqueued: [Enqueued] = []

    var enqueued: [Enqueued] { lock.withLock { _enqueued } }
    var count: Int { lock.withLock { _enqueued.count } }

    /// The keys the queue would collapse on. `NetworkQueue.addRequest` UPDATEs
    /// the row matching `(libraryID, updateID)`, so two writes sharing an
    /// updateID overwrite each other — which is correct for reading positions
    /// and data loss for bookmarks.
    var updateIDs: [String?] { lock.withLock { _enqueued.map(\.updateID) } }

    func addRequest(_ libraryID: String,
                    _ updateID: String?,
                    _ requestUrl: URL,
                    _ method: HTTPMethodType,
                    _ parameters: Data?,
                    _ headers: [String: String]?) {
        lock.withLock {
            _enqueued.append(Enqueued(libraryID: libraryID,
                                      updateID: updateID,
                                      url: requestUrl,
                                      method: method,
                                      parameters: parameters,
                                      headers: headers))
        }
    }
}
