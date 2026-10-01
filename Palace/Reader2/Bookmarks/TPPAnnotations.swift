import UIKit
import ReadiumShared
import PalaceLogging
import PalaceBookModel

public struct AnnotationResponse: Sendable {
    var serverId: String?
    var timeStamp: String?
}

/// Provides a stable device identifier for annotation sync.
///
/// Prefers the Adobe DRM device ID (set during device activation) for
/// backwards compatibility with existing annotations. Falls back to the
/// Firebase-managed device ID (persisted in UserDefaults) so that
/// non-DRM users still get working cross-device sync detection.
enum AnnotationDevice {
    /// Test-only seam mirroring `TPPAnnotations.accountsManagerOverride`.
    /// Always `nil` in production.
    nonisolated(unsafe) static var accountsManagerOverride: TPPUserAccountResolving?

    /// Test-only seam for the Firebase-managed device UUID. When non-nil,
    /// `currentID()` uses this string instead of `FirebaseManager.shared.deviceID`.
    /// Always `nil` in production. Reset in `tearDown`.
    nonisolated(unsafe) static var firebaseDeviceIDOverride: String?

    static func currentID() -> String {
        let accountsManager: TPPUserAccountResolving = accountsManagerOverride ?? AppContainer.production().accountsManager
        if let adobeID = accountsManager.currentUserAccount.deviceID, !adobeID.isEmpty {
            return adobeID
        }
        let firebaseDeviceID = firebaseDeviceIDOverride ?? FirebaseManager.shared.deviceID
        // The spec's fallback for a client with no identifier of this form is
        // the literal four-character string "null" — which is also what the
        // Android client sends. An empty `urn:uuid:` prefix would be worse
        // than either, so guard it rather than emit a malformed URN.
        guard !firebaseDeviceID.isEmpty else { return "null" }
        return "urn:uuid:\(firebaseDeviceID)"
    }
}

protocol AnnotationsManager {
    var syncIsPossibleAndPermitted: Bool { get }
    func postListeningPosition(forBook bookID: String, selectorValue: String, completion: ((_ response: AnnotationResponse?) -> Void)?)
    func postAudiobookBookmark(forBook bookID: String, selectorValue: String) async throws -> AnnotationResponse?
    func getServerBookmarks(forBook book: TPPBook?,
                            atURL annotationURL: URL?,
                            motivation: TPPBookmarkSpec.Motivation,
                            completion: @escaping (_ bookmarks: [Bookmark]?) -> Void)
    func deleteBookmark(annotationId: String, completionHandler: @escaping (_ success: Bool) -> Void)
    func deleteAllBookmarks(forBook book: TPPBook, completion: @escaping () -> Void)
}

@objcMembers final class TPPAnnotationsWrapper: NSObject, AnnotationsManager {
    var syncIsPossibleAndPermitted: Bool { TPPAnnotations.syncIsPossibleAndPermitted() }

    func postListeningPosition(forBook bookID: String, selectorValue: String, completion: ((_ response: AnnotationResponse?) -> Void)?) {
        TPPAnnotations.postListeningPosition(forBook: bookID, selectorValue: selectorValue, completion: completion)
    }

    func postAudiobookBookmark(forBook bookID: String, selectorValue: String) async throws -> AnnotationResponse? {
        try await TPPAnnotations.postAudiobookBookmark(forBook: bookID, selectorValue: selectorValue)
    }

    func getServerBookmarks(forBook book: TPPBook?, atURL annotationURL: URL?, motivation: TPPBookmarkSpec.Motivation = .bookmark, completion: @escaping ([Bookmark]?) -> Void) {
        TPPAnnotations.getServerBookmarks(forBook: book, atURL: annotationURL, motivation: motivation, completion: completion)
    }

    func deleteBookmark(annotationId: String, completionHandler: @escaping (Bool) -> Void) {
        TPPAnnotations.deleteBookmark(annotationId: annotationId, completionHandler: completionHandler)
    }

    func deleteAllBookmarks(forBook book: TPPBook, completion: @escaping () -> Void) {
        TPPAnnotations.deleteAllBookmarks(forBook: book, completion: completion)
    }
}

@objcMembers final class TPPAnnotations: NSObject {

    // MARK: - Test seams
    //
    // TPPAnnotations is a static-class API, so dependencies cannot be injected
    // via init. Each dependency reach is gated by an override that defaults to
    // `nil`; tests set it in setUp and clear it in tearDown. Never set these
    // from production code.
    nonisolated(unsafe) static var executorOverride: TPPNetworkExecutor?
    nonisolated(unsafe) static var accountsManagerOverride: TPPLibraryAccountsProvider?

    /// Test-only seam for observing what this type hands to the offline queue,
    /// and for keeping tests from writing rows into the real `simplified.db`.
    /// Never set from production code.
    nonisolated(unsafe) static var offlineQueueOverride: AnnotationOfflineQueueing?

    /// Test-only seam for observing what this type reports to error logging
    /// (PP-4965). Never set from production code.
    nonisolated(unsafe) static var errorLoggerOverride: ErrorLogging?

    /// Test-only override for the annotations URL. CI runners have no signed-in
    /// library, so `mainFeedURL()` is nil and every annotation request would
    /// early-return. Never set from production code.
    nonisolated(unsafe) static var annotationsURLOverride: URL?

    // MARK: - Deletion-chain test join seam
    //
    // `deleteAllBookmarks` calls its completion immediately and runs a GET plus
    // N chained DELETEs in the background, so tests cannot wait on the
    // completion. Each call gets its own DispatchGroup counting its in-flight
    // chain, published for tests to join. Per-call so an unjoined call in one
    // suite cannot hang another. Created only under XCTest; in production every
    // `?.enter()` / `?.leave()` is a no-op.
    private static let _isRunningUnderXCTest =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private static let _deletionChainLock = NSLock()
    nonisolated(unsafe) private static var _lastDeletionChain: DispatchGroup?

    /// Publishes a fresh group for the chain that is about to start, or `nil`
    /// outside XCTest.
    private static func _beginDeletionChainTracking() -> DispatchGroup? {
        guard _isRunningUnderXCTest else { return nil }
        let group = DispatchGroup()
        _deletionChainLock.lock()
        _lastDeletionChain = group
        _deletionChainLock.unlock()
        return group
    }

    /// Synchronous lock-guarded read of the published chain, split out because
    /// `NSLock` is unavailable from an async context in Swift 6.
    private static func _snapshotLastDeletionChain() -> DispatchGroup? {
        _deletionChainLock.lock()
        defer { _deletionChainLock.unlock() }
        return _lastDeletionChain
    }

    /// Suspends until the MOST RECENT `deleteAllBookmarks` chain has fully
    /// settled — its GET completed and every DELETE it spawned called back.
    /// Returns immediately if no chain has started. Test-only; no-ops outside
    /// XCTest. Call it right after the `deleteAllBookmarks` whose effects you
    /// are about to assert on.
    static func _awaitDeletionChainForTesting() async {
        guard let group = _snapshotLastDeletionChain() else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { continuation.resume() }
        }
    }

    /// Returns the executor TPPAnnotations should use for the current call.
    /// In production this is always `.shared`. In tests, setting
    /// `executorOverride` lets the test inject a stubbed executor.
    fileprivate static var currentExecutor: TPPNetworkExecutor {
        return executorOverride ?? AppContainer.production().networkExecutor
    }

    /// Returns the accounts provider TPPAnnotations should use for the
    /// current call. In production this is always `.shared`. In tests,
    /// setting `accountsManagerOverride` lets the test inject a mock.
    fileprivate static var currentAccountsManager: TPPLibraryAccountsProvider {
        return accountsManagerOverride ?? AppContainer.production().accountsManager
    }

    /// Where a queued-for-retry write is handed off. Production resolves to the
    /// container's queue; tests inject a double.
    fileprivate static var currentOfflineQueue: AnnotationOfflineQueueing {
        return offlineQueueOverride ?? AppContainer.production().networkQueue
    }

    private static let defaultErrorLogger = DefaultErrorLogger()

    /// Returns the error logger TPPAnnotations should report to. In tests,
    /// setting `errorLoggerOverride` lets the test observe what was reported.
    fileprivate static var currentErrorLogger: ErrorLogging {
        return errorLoggerOverride ?? defaultErrorLogger
    }

    // MARK: - Reading Position

    /// Asynchronously syncs the reading position of a book.
    /// - Parameters:
    ///   - book: The `TPPBook` whose reading position is being synced.
    ///   - url: The server URL for syncing the reading position.
    /// - Returns: The most recent reading position (`Bookmark?`) from the server.
    static func syncReadingPosition(ofBook book: TPPBook?, toURL url: URL?) async -> Bookmark? {
        guard syncIsPossibleAndPermitted() else {
            Log.debug(#file, "Account does not support sync or sync is disabled.")
            return nil
        }

        // `Bookmark` is non-Sendable, so box the one bookmark needed to cross
        // the continuation boundary (see `BookmarkBox`).
        let firstBox: BookmarkBox = await withCheckedContinuation { continuation in
            var didResume = false

            getServerBookmarks(forBook: book, atURL: url, motivation: .readingProgress) { bookmarks in
                guard !didResume else { return }
                didResume = true

                continuation.resume(returning: BookmarkBox(bookmarks?.first))
            }
        }

        return firstBox.bookmark
    }

    static func postListeningPosition(forBook bookID: String, selectorValue: String, completion: ((_ response: AnnotationResponse?) -> Void)? = nil) {
        postReadingPosition(forBook: bookID, selectorValue: selectorValue, motivation: .readingProgress, completion: completion)
    }

    static func postAudiobookBookmark(forBook bookID: String, selectorValue: String) async throws -> AnnotationResponse? {
        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false

            postReadingPosition(forBook: bookID, selectorValue: selectorValue, motivation: .bookmark) { response in
                // The double-resume guard is checked here, outside the
                // `@Sendable` main-queue hop, which cannot mutate a captured `var`.
                guard !didResume else { return }
                didResume = true

                DispatchQueue.main.async {
                    if let response {
                        continuation.resume(returning: response)
                    } else {
                        continuation.resume(throwing: NSError(domain: "Error posting bookmark", code: 1, userInfo: nil))
                    }
                }
            }
        }
    }

    static func postReadingPosition(forBook bookID: String, selectorValue: String, motivation: TPPBookmarkSpec.Motivation, completion: ((_ response: AnnotationResponse?) -> Void)? = nil) {
        guard syncIsPossibleAndPermitted() else {
            Log.debug(#file, "Account does not support sync or sync is disabled.")
            completion?(nil)
            return
        }

        guard let annotationsURL = TPPAnnotations.annotationsURL else {
            Log.error(#file, "Annotations URL was nil while updating reading position")
            completion?(nil)
            return
        }

        // PP-5138: the spec asks for a UUID URN device, or the literal "null";
        // `AnnotationDevice.currentID()` supplies that, including for libraries
        // without Adobe DRM, which cross-device detection depends on.
        let bookmark = TPPBookmarkSpec(time: NSDate(),
                                       device: AnnotationDevice.currentID(),
                                       motivation: motivation,
                                       bookID: bookID,
                                       selectorValue: selectorValue)
        let parameters = bookmark.dictionaryForJSONSerialization()

        // The offline queue UPDATES the row matching (libraryID, queueKey), so
        // the key decides what supersedes what (PP-4987 made this reachable):
        //
        //  - readingProgress: key on the book. Collapsing IS correct — a newer
        //    position supersedes an older one for the same book, and delivering
        //    only the latest is what the patron wants.
        //  - bookmark: key on the book AND the selector, so two offline
        //    bookmarks in one title do not overwrite each other.
        let queueKey: String
        switch motivation {
        case .bookmark:
            queueKey = "\(bookID)|\(selectorValue)"
        default:
            queueKey = bookID
        }

        postAnnotation(forBook: bookID, withAnnotationURL: annotationsURL, withParameters: parameters, queueOffline: true, queueKey: queueKey) { result in
            switch result {
            case let .succeeded(id, timeStamp):
                Log.debug(#file, "Successfully saved Reading Position to server: \(selectorValue)")
                completion?(AnnotationResponse(serverId: id, timeStamp: timeStamp))

            case .queuedForRetry:
                // NOT an error. The position is already in local storage and the
                // write is queued for delivery. Reporting this was the bulk of
                // the "Error posting annotation" volume (PP-4965).
                Log.debug(#file, "Reading position for \(bookID) queued for retry")
                completion?(nil)

            case let .failed(underlying, response):
                Log.warn(#file, "Annotation POST failed for \(bookID)")
                var metadata: [String: Any] = [
                    "bookID": bookID,
                    "annotationURL": annotationsURL,
                    "motivation": motivation.rawValue
                ]
                if let statusCode = response?.statusCode {
                    metadata["statusCode"] = statusCode
                }
                // `logNetworkError`, not `logError`: the bare overload hardcodes
                // `code: .ignore`, which would move this bucket off 902
                // (`.apiCall`) and lose the server origin. This keeps `.apiCall`,
                // routes through `fixUpSummary`, and lets 400...599 classify as
                // `.server`.
                Self.currentErrorLogger.logNetworkError(underlying,
                                                        code: .apiCall,
                                                        summary: "Error posting annotation",
                                                        request: nil,
                                                        response: response,
                                                        metadata: metadata)
                completion?(nil)
            }
        }
    }

    static func postBookmark(_ page: TPPPDFPage, annotationsURL: URL?, forBookID bookID: String, completion: @escaping (_ annotationResponse: AnnotationResponse?) -> Void) {
        guard syncIsPossibleAndPermitted() else {
            Log.debug(#file, "Account does not support sync or sync is disabled.")
            completion(nil)
            return
        }

        guard let annotationsURL = annotationsURL ?? TPPAnnotations.annotationsURL else {
            Log.error(#file, "Annotations URL was nil while posting bookmark")
            return
        }

        guard let selectorValue = page.bookmarkSelector else {
            Log.error(#file, "Bookmark selectorValue was nil while posting bookmark")
            return
        }

        let spec = TPPBookmarkSpec(
            time: NSDate(),
            device: Self.currentAccountsManager.currentUserAccount.deviceID ?? "",
            motivation: .bookmark,
            bookID: bookID,
            selectorValue: selectorValue
        )

        let parameters = spec.dictionaryForJSONSerialization()

        postAnnotation(forBook: bookID, withAnnotationURL: annotationsURL, withParameters: parameters, queueOffline: false) { result in
            // A failed bookmark POST calls back with an empty response and
            // reports nothing; adding telemetry here is tracked separately.
            guard case let .succeeded(id, timeStamp) = result else {
                completion(AnnotationResponse(serverId: nil, timeStamp: nil))
                return
            }
            completion(AnnotationResponse(serverId: id, timeStamp: timeStamp))
        }
    }

    static func postBookmark(_ bookmark: TPPReadiumBookmark,
                            forBookID bookID: String,
                            completion: @escaping (_ annotationResponse: AnnotationResponse?) -> Void) {
        guard syncIsPossibleAndPermitted() else {
            Log.debug(#file, "Account does not support sync or sync is disabled.")
            completion(nil)
            return
        }

        guard let annotationsURL = TPPAnnotations.annotationsURL else {
            Log.error(#file, "Annotations URL was nil while posting bookmark")
            return
        }

        let spec = TPPBookmarkSpec(
            id: UUID().uuidString,
            time: (bookmark.time.dateFromISO8601 as NSDate? ?? NSDate()),
            device: bookmark.device ?? "",
            motivation: .bookmark,
            bookID: bookID,
            selectorValue: bookmark.location
        )

        let parameters = spec.dictionaryForJSONSerialization()

        postAnnotation(forBook: bookID, withAnnotationURL: annotationsURL, withParameters: parameters, queueOffline: false) { result in
            // A failed bookmark POST calls back with an empty response and
            // reports nothing; adding telemetry here is tracked separately.
            guard case let .succeeded(id, timeStamp) = result else {
                completion(AnnotationResponse(serverId: nil, timeStamp: nil))
                return
            }
            completion(AnnotationResponse(serverId: id, timeStamp: timeStamp))
        }
    }

    /// How a POST to the annotations endpoint concluded.
    ///
    /// PP-4965: `queuedForRetry` is distinct from `failed` because a queued
    /// write has not been lost and must not be reported as a failure.
    enum AnnotationPostResult {
        /// The server accepted the annotation. Both values may still be nil if
        /// the response body was missing or unparseable.
        case succeeded(annotationID: String?, timeStamp: String?)

        /// Transport failed, but the request was handed to the offline queue
        /// and will be retried. Delivery is pending, not lost — do not report
        /// this as an error. Reachable since PP-4987.
        case queuedForRetry

        /// The write did not happen and nothing will retry it.
        ///
        /// `underlying` carries the transport error where there was one, so the
        /// logger's existing classifier can separate transient conditions (no
        /// connection, timeout) from real defects. `response` is present when
        /// the server answered and refused — it is carried whole rather than as
        /// a bare status code so `TPPErrorOrigin.classify` can read 400...599
        /// off it and attribute the failure to the server.
        case failed(underlying: NSError?, response: HTTPURLResponse?)
    }

    /// Serializes the `parameters` into JSON and POSTs them to the server.
    static func postAnnotation(forBook bookID: String,
                              withAnnotationURL url: URL,
                              withParameters parameters: [String: Any],
                              timeout: TimeInterval = TPPDefaultRequestTimeout,
                              queueOffline: Bool,
                              queueKey: String? = nil,
                              _ completionHandler: @escaping (_ result: AnnotationPostResult) -> Void) {

        // `isValidJSONObject` first: `data(withJSONObject:)` raises an ObjC
        // exception for unsupported types, which `try?` does not catch.
        guard JSONSerialization.isValidJSONObject(parameters),
              let jsonData = try? JSONSerialization.data(withJSONObject: parameters,
                                                         options: [.prettyPrinted]) else {
            Log.error(#file, "Network request abandoned. Could not create JSON from given parameters.")
            completionHandler(.failed(underlying: nil, response: nil))
            return
        }

        var request = Self.currentExecutor.request(for: url)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        let task = Self.currentExecutor.POST(request, useTokenIfAvailable: true) { (data, response, error) in
            if let error = error as NSError? {
                let willQueueOffline = (NetworkQueue.StatusCodes.contains(error.code)) && (queueOffline == true)

                // Always log error details for investigation
                Log.error(#file, "Annotation POST error (code: \(error.code)): \(error.localizedDescription)")

                if willQueueOffline {
                    Log.debug(#file, "Queued for offline retry")
                    self.addToOfflineQueue(queueKey ?? bookID, url, parameters)
                    completionHandler(.queuedForRetry)
                    return
                }

                // Carry the response: `TPPNetworkResponder` synthesizes an
                // NSError for every non-2xx, so a server refusal takes this
                // branch, and `TPPErrorOrigin.classify` needs the status code.
                completionHandler(.failed(underlying: error,
                                          response: response as? HTTPURLResponse))
                return
            }
            guard let statusCode = (response as? HTTPURLResponse)?.statusCode else {
                Log.error(#file, "Annotation POST error: No response received from server")
                completionHandler(.failed(underlying: nil, response: nil))
                return
            }

            if statusCode == 200 {
                Log.debug(#file, "Annotation POST: Success 200.")
                let serverAnnotationID = annotationID(fromNetworkData: data)
                let timeStamp = timeStamp(fromNetworkData: data)
                completionHandler(.succeeded(annotationID: serverAnnotationID, timeStamp: timeStamp))
            } else {
                Log.error(#file, "Annotation POST: Response Error. Status Code: \(statusCode)")
                completionHandler(.failed(underlying: nil, response: response as? HTTPURLResponse))
            }
        }
        task?.resume()
    }

    /// Parses the LD+JSON annotation envelope, extracts items from `first.items`,
    /// and converts each to a domain bookmark via `TPPBookmarkFactory`.
    /// Exposed as internal (not private) so fuzz and contract tests can exercise
    /// the real parsing chain without needing a network call.
    static func parseAnnotationItems(fromData data: Data) -> [[String: Any]]? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let first = json["first"] as? [String: Any],
              let items = first["items"] as? [[String: Any]] else {
            return nil
        }
        return items
    }

    static func annotationID(fromNetworkData data: Data?) -> String? {
        guard let data = data else {
            Log.error(#file, "No Annotation ID saved: No data received from server.")
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            Log.error(#file, "No Annotation ID saved: JSON could not be created from data.")
            return nil
        }
        if let annotationID = json[TPPBookmarkSpec.Id.key] as? String {
            return annotationID
        } else {
            Log.error(#file, "No Annotation ID saved: Key/Value not found in JSON response.")
            return nil
        }
    }

    static func timeStamp(fromNetworkData data: Data?) -> String? {
        guard let data = data else {
            Log.error(#file, "No Annotation ID saved: No data received from server.")
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            Log.error(#file, "No Annotation ID saved: JSON could not be created from data.")
            return nil
        }
        if let body = json[TPPBookmarkSpec.Body.key] as? [String: Any], let timeStamp = body[TPPBookmarkSpec.Body.Time.key] as? String {
            return timeStamp
        } else {
            Log.error(#file, "No Annotation ID saved: Key/Value not found in JSON response.")
            return nil
        }
    }

    // MARK: - Bookmarks

    // Completion handler will return a nil parameter if there are any failures with
    // the network request, deserialization, or sync permission is not allowed.
    static func getServerBookmarks(forBook book: TPPBook?,
                                  atURL annotationURL: URL?,
                                  motivation: TPPBookmarkSpec.Motivation = .bookmark,
                                  completion: @escaping (_ bookmarks: [Bookmark]?) -> Void) {

        guard syncIsPossibleAndPermitted() else {
            Log.debug(#file, "📡 getServerBookmarks: Account does not support sync or sync is disabled.")
            completion(nil)
            return
        }

        guard let book, let annotationURL else {
            Log.error(#file, "📡 getServerBookmarks: Required parameter was nil.")
            completion(nil)
            return
        }

        Log.info(#file, "📡 GET SERVER BOOKMARKS for book: \(book.identifier), URL: \(annotationURL.absoluteString), motivation: \(motivation.rawValue)")

        let dataTask = Self.currentExecutor.GET(annotationURL, useTokenIfAvailable: true) { (data, response, error) in

            if let error = error as NSError? {
                Log.error(#file, "📡 Request Error Code: \(error.code). Description: \(error.localizedDescription)")
                completion(nil)
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                Log.info(#file, "📡 Server Response Status Code: \(httpResponse.statusCode)")
            }

            guard let data,
                  let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
                  let json = jsonObject as? [String: Any] else {
                Log.error(#file, "📡 Response from annotation server could not be serialized.")
                if let data = data, let responseString = String(data: data, encoding: .utf8) {
                    Log.error(#file, "📡 Raw response: \(responseString.prefix(500))")
                }
                completion(nil)
                return
            }

            guard let first = json["first"] as? [String: Any],
                  let items = first["items"] as? [[String: Any]] else {
                Log.error(#file, "📡 Missing required key from Annotations response, or no items exist.")
                Log.info(#file, "📡 JSON keys: \(json.keys)")
                completion(nil)
                return
            }

            Log.info(#file, "📡 RAW SERVER ITEMS COUNT: \(items.count)")

            for (index, item) in items.enumerated() {
                if let annotationId = item[TPPBookmarkSpec.Id.key] as? String,
                   let body = item[TPPBookmarkSpec.Body.key] as? [String: Any],
                   let time = body[TPPBookmarkSpec.Body.Time.key] as? String,
                   let target = item[TPPBookmarkSpec.Target.key] as? [String: Any],
                   let source = target[TPPBookmarkSpec.Target.Source.key] as? String {
                    Log.info(#file, "📡 Raw Item #\(index): id=\(annotationId), timestamp=\(time), bookId=\(source)")
                } else {
                    Log.warn(#file, "📡 Raw Item #\(index): Could not extract basic info from annotation")
                }
            }

            let bookmarks = items.compactMap {
                TPPBookmarkFactory.make(fromServerAnnotation: $0,
                                        annotationType: motivation,
                                        book: book)
            }

            Log.info(#file, "📡 PARSED BOOKMARKS COUNT: \(bookmarks.count) (from \(items.count) raw items)")

            if bookmarks.count < items.count {
                // `/annotations/` returns the patron's annotations for every
                // book, so most skipped items belong to other books rather than
                // failing to parse; logged at info for that reason. A CM-side
                // per-book filter would cut the cold-open payload.
                Log.info(#file, "📡 Filtered \(items.count - bookmarks.count) items belonging to other books (kept \(bookmarks.count) for \(book.identifier))")
            }

            completion(bookmarks)
        }

        dataTask?.resume()
    }

    static func deleteBookmarks(_ bookmarks: [TPPReadiumBookmark]) {

        for localBookmark in bookmarks {
            if let annotationID = localBookmark.annotationId {
                deleteBookmark(annotationId: annotationID) { success in
                    if success {
                        Log.debug(#file, "Server bookmark deleted: \(annotationID)")
                    } else {
                        Log.error(#file, "Bookmark not deleted from server. Moving on: \(annotationID)")
                    }
                }
            }
        }
    }

    /// Deletes all bookmarks for a book from the server.
    /// This should be called when a book is returned to prevent old bookmarks
    /// from reappearing when the book is re-borrowed.
    ///
    /// **Important:** This is fire-and-forget. Completion is called immediately,
    /// and deletions happen in the background. Book returns are never blocked.
    ///
    /// - Parameters:
    ///   - book: The book whose bookmarks should be deleted
    ///   - completion: Called immediately. Deletions continue in background.
    static func deleteAllBookmarks(forBook book: TPPBook, completion: @escaping () -> Void) {
        // Publish this call's chain before anything can return, so a test that
        // joins right after `completion()` never sees a stale chain. Every early
        // return below must `leave()`. Nil outside XCTest.
        let chain = _beginDeletionChainTracking()
        chain?.enter()

        // Call completion immediately - never block book returns
        completion()

        // Fire-and-forget: delete bookmarks in background
        guard syncIsPossibleAndPermitted() else { chain?.leave(); return }

        // Delete USER bookmarks (`.bookmark`) only. The READING POSITION
        // (`.readingProgress`) is deliberately preserved for every format —
        // ebook, PDF, and audiobook alike.
        //
        // No shipped build has deleted the position on return. Doing so would be
        // a product decision (and inconsistent: audiobooks but not ebooks,
        // return but not loan expiry), so pending sign-off a patron who
        // re-borrows keeps their place.
        //
        // The GET's `leave()` is deferred to the END of its completion so the
        // group cannot reach zero in the window between the GET finishing and
        // its DELETEs being entered. (`chain` was entered at the top.)
        getServerBookmarks(forBook: book, atURL: book.annotationsURL, motivation: .bookmark) { bookmarks in
            defer { chain?.leave() }
            guard let bookmarks, !bookmarks.isEmpty else { return }
            for bookmark in bookmarks {
                guard let annotationId = serverAnnotationId(of: bookmark) else { continue }
                chain?.enter()
                deleteBookmark(annotationId: annotationId) { _ in
                    chain?.leave()
                }
            }
        }
    }

    /// Extracts the server annotation ID from a parsed `Bookmark`, regardless
    /// of concrete type (an `as? [TPPReadiumBookmark]` cast would drop audiobook
    /// bookmarks). Returns `nil` for a bookmark with no server linkage or an
    /// unrecognised type (e.g. an unsynced `AudioBookmark`, or a PDF page
    /// bookmark).
    private static func serverAnnotationId(of bookmark: Bookmark) -> String? {
        if let readium = bookmark as? TPPReadiumBookmark {
            return readium.annotationId
        }
        if let audio = bookmark as? AudioBookmark {
            return audio.annotationId.isEmpty ? nil : audio.annotationId
        }
        return nil
    }

    static func deleteBookmark(annotationId: String,
                              completionHandler: @escaping (_ success: Bool) -> Void) {

        if !syncIsPossibleAndPermitted() {
            completionHandler(true)
            return
        }

        guard let url = URL(string: annotationId) else {
            Log.error(#file, "Invalid annotation ID URL: \(annotationId)")
            completionHandler(false)
            return
        }

        var request = Self.currentExecutor.request(for: url)
        request.timeoutInterval = TPPDefaultRequestTimeout

        let task = Self.currentExecutor.DELETE(request, useTokenIfAvailable: true) { (_, response, error) in
            let response = response as? HTTPURLResponse
            if response?.statusCode == 200 {
                Log.info(#file, "200: DELETE bookmark success")
                completionHandler(true)
            } else if response?.statusCode == 404 {
                Log.error(#file, "Bookmark is no longer on the server")
                completionHandler(true)
            } else if let code = response?.statusCode {
                Log.error(#file, "DELETE bookmark failed with server response code: \(code)")
                completionHandler(false)
            } else {
                // A nil response and nil error must still call the completion,
                // or every caller waits forever.
                let nsError = error as NSError?
                Log.error(#file, "DELETE bookmark Request Failed with Error Code: \(nsError?.code ?? -1). Description: \(nsError?.localizedDescription ?? "no response and no error")")
                completionHandler(false)
            }
        }

        if let task {
            task.resume()
        } else {
            // Defensive, and currently unreachable: the ONLY `nil` return from
            // `TPPNetworkExecutor.executeRequest` is the proactive-token-refresh
            // deferral, which is gated on `enableTokenRefresh` — and `DELETE`
            // passes `enableTokenRefresh: false`. Keep that in sync: if DELETE
            // ever enables refresh, this branch would DOUBLE-call the handler
            // (once here, once when the deferred request completes), which would
            // also double-`leave()` the deletion-chain group under test.
            Log.error(#file, "DELETE bookmark could not create a request task for \(annotationId)")
            completionHandler(false)
        }
    }

    static func uploadLocalBookmarks(_ bookmarks: [TPPReadiumBookmark],
                                    forBook bookID: String,
                                    completion: @escaping ([TPPReadiumBookmark], [TPPReadiumBookmark]) -> Void) {
        if !syncIsPossibleAndPermitted() {
            Log.debug(#file, "Account does not support sync or sync is disabled.")
            return
        }

        Log.debug(#file, "Begin task of uploading local bookmarks, count: \(bookmarks.count).")
        let uploadGroup = DispatchGroup()
        // Non-Sendable accumulators are boxed; see `BookmarkUploadAccumulatorBox`.
        let accumulator = BookmarkUploadAccumulatorBox(completion: completion)

        for localBookmark in bookmarks {
            guard localBookmark.annotationId == nil else { continue }

            let bookmarkBox = ReadiumBookmarkBox(localBookmark)
            uploadGroup.enter()
            postBookmark(localBookmark, forBookID: bookID) { response in
                DispatchQueue.main.async {
                    defer { uploadGroup.leave() }

                    let localBookmark = bookmarkBox.bookmark
                    if let serverId = response?.serverId {
                        localBookmark.annotationId = serverId
                        accumulator.updated.append(localBookmark)
                    } else {
                        Log.error(#file, "Local Bookmark not uploaded: \(localBookmark)")
                        accumulator.failed.append(localBookmark)
                    }
                }
            }
        }

        uploadGroup.notify(queue: DispatchQueue.main) {
            Log.debug(#file, "Finished task of uploading local bookmarks.")
            accumulator.completion(accumulator.updated, accumulator.failed)
        }
    }
    // MARK: -

    /// Returns the account details only in `.detailsLoaded`; every other state
    /// yields nil so sync never reads a partially-populated auth document.
    /// Bookmark sync is best-effort, so skipping it during loading is correct.
    fileprivate static func loadedDetails(of account: Account?) -> AccountDetails? {
        guard let account = account,
              case .detailsLoaded(let details) = account.loadState else {
            return nil
        }
        return details
    }

    /// Annotation-syncing is possible only if the given `account` is signed-in
    /// and if the currently selected library supports it.
    ///
    /// `accountsManager` defaults to the test-aware
    /// `currentAccountsManager` accessor, so tests that set
    /// `accountsManagerOverride` are honored without needing to pass an
    /// argument from every call site.
    static func syncIsPossible(_ account: TPPUserAccount, accountsManager: TPPLibraryAccountsProvider? = nil) -> Bool {
        let manager = accountsManager ?? Self.currentAccountsManager
        let library = manager.currentAccount
        return account.hasCredentials() && loadedDetails(of: library)?.supportsSimplyESync == true
    }

    static func syncIsPossibleAndPermitted(accountsManager: TPPLibraryAccountsProvider? = nil) -> Bool {
        let manager = accountsManager ?? Self.currentAccountsManager
        let account = manager.currentUserAccount
        let acct = manager.currentAccount
        let details = loadedDetails(of: acct)
        let hasCreds = account.hasCredentials()
        let supportsSync = details?.supportsSimplyESync == true
        let permissionGranted = details?.syncPermissionGranted == true
        let result = hasCreds && supportsSync && permissionGranted

        if !result {
            Log.debug(#file, "syncIsPossibleAndPermitted=\(result): hasCredentials=\(hasCreds), supportsSimplyESync=\(supportsSync), syncPermissionGranted=\(permissionGranted), loadedDetails=\(details != nil ? "present" : "nil (state-machine not yet .detailsLoaded)")")
        }

        return result
    }

    static var annotationsURL: URL? {
        if let override = annotationsURLOverride {
            return override
        }
        return TPPConfiguration.mainFeedURL()?.appendingPathComponent("annotations/")
    }

    private static func addToOfflineQueue(_ bookID: String?, _ url: URL, _ parameters: [String: Any], accountsManager: TPPLibraryAccountsProvider? = nil, networkExecutor: TPPNetworkExecutor? = nil) {
        let manager = accountsManager ?? Self.currentAccountsManager
        let executor = networkExecutor ?? Self.currentExecutor
        let libraryID = manager.currentAccount?.uuid ?? ""
        let parameterData = try? JSONSerialization.data(withJSONObject: parameters, options: [.prettyPrinted])
        let headers = executor.request(for: url).allHTTPHeaderFields
        Self.currentOfflineQueue.addRequest(libraryID, bookID, url, .POST, parameterData, headers)
    }
}

/// The slice of the offline queue that annotation writes actually use.
///
/// Exists so tests can observe that a write reached the queue.
/// `NetworkQueue` already has this exact signature.
protocol AnnotationOfflineQueueing: AnyObject {
    func addRequest(_ libraryID: String,
                    _ updateID: String?,
                    _ requestUrl: URL,
                    _ method: HTTPMethodType,
                    _ parameters: Data?,
                    _ headers: [String: String]?)
}

extension NetworkQueue: AnnotationOfflineQueueing {}

// MARK: - Sendable carriers for the annotation-sync @Sendable-closure captures

/// Sendable carrier for a non-Sendable `Bookmark?` crossing the continuation
/// boundary in `syncReadingPosition`. Invariant: produced once in the
/// `getServerBookmarks` completion, read once after the continuation resumes.
private final class BookmarkBox: @unchecked Sendable {
    let bookmark: Bookmark?
    init(_ bookmark: Bookmark?) { self.bookmark = bookmark }
}

/// Sendable carrier for a single non-Sendable `TPPReadiumBookmark` handed to the
/// `@Sendable` `DispatchQueue.main.async` upload-completion in
/// `uploadLocalBookmarks`. Invariant: the boxed bookmark's `annotationId` is
/// mutated only on the main queue inside that completion.
private final class ReadiumBookmarkBox: @unchecked Sendable {
    let bookmark: TPPReadiumBookmark
    init(_ bookmark: TPPReadiumBookmark) { self.bookmark = bookmark }
}

/// Sendable carrier for the mutable `[TPPReadiumBookmark]` accumulators and the
/// non-Sendable completion in `uploadLocalBookmarks`. Invariant: `updated` and
/// `failed` are appended to only inside per-upload `DispatchQueue.main.async`
/// blocks and read only inside the `uploadGroup.notify(queue: .main)` terminal,
/// which the DispatchGroup orders after every append.
private final class BookmarkUploadAccumulatorBox: @unchecked Sendable {
    var updated: [TPPReadiumBookmark] = []
    var failed: [TPPReadiumBookmark] = []
    let completion: ([TPPReadiumBookmark], [TPPReadiumBookmark]) -> Void
    init(completion: @escaping ([TPPReadiumBookmark], [TPPReadiumBookmark]) -> Void) {
        self.completion = completion
    }
}
