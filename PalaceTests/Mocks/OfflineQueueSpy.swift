//
//  Records what `TPPAnnotations` hands to the offline retry queue. PP-4987 made
//  `.queuedForRetry` reachable, and PP-4965 drops the error report for a queued
//  write on that basis, so tests need to assert the write was stored, not only
//  that nothing was reported. Also keeps the cross-device suite out of the real
//  `simplified.db`.
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
