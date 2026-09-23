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
///
/// - Important: Prior to this fix, non-Adobe-DRM users sent an empty
///   string, which made cross-device sync prompts impossible because
///   both devices appeared to be the same device.
enum AnnotationDevice {
    /// Test-only seam mirroring `TPPAnnotations.accountsManagerOverride`.
    /// When non-nil, `currentID()` reads `currentUserAccount.deviceID`
    /// from this provider instead of the AppContainer instance. Typed as
    /// the `TPPUserAccountResolving` protocol so tests can inject mock
    /// providers without subclassing the final `AccountsManager`.
    /// Always `nil` in production. Reset in `tearDown`.
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
    // TPPAnnotations is a static-class API, so we cannot inject deps via init.
    // Instead, each `.shared` reach is gated by an override property that
    // defaults to `nil`; production keeps `.shared`, tests inject a mock.
    // This mirrors the architectural-triad refactor for instance classes
    // that take an `AppContainer`, but adapted for the static-class shape.
    //
    // The accountsManager seam is typed as `TPPLibraryAccountsProvider`
    // (the protocol) rather than `AccountsManager` (the final concrete
    // class) so that tests can substitute lightweight mocks.
    //
    // Test usage:
    //   override func setUp() {
    //     TPPAnnotations.executorOverride = mockExecutor
    //     TPPAnnotations.accountsManagerOverride = mockAccountsManager
    //   }
    //   override func tearDown() {
    //     TPPAnnotations.executorOverride = nil
    //     TPPAnnotations.accountsManagerOverride = nil
    //   }
    //
    // Never set these from production code.
    nonisolated(unsafe) static var executorOverride: TPPNetworkExecutor?
    nonisolated(unsafe) static var accountsManagerOverride: TPPLibraryAccountsProvider?

    /// Test-only seam for observing what this type hands to the offline queue.
    /// PP-4987 made `.queuedForRetry` reachable, so "the write actually reached
    /// the queue" became a real claim — and it was previously unassertable,
    /// because `addToOfflineQueue` reaches `AppContainer.production()`
    /// directly. That also meant the cross-device test wrote durable rows into
    /// the app's REAL `simplified.db`, which a later reachability event could
    /// replay. Never set from production code.
    nonisolated(unsafe) static var offlineQueueOverride: AnnotationOfflineQueueing?

    /// Test-only seam for observing what this type reports to error logging.
    /// PP-4965: whether a failed position write is reported at all — and with
    /// what underlying error — is now behaviour worth asserting, so it needs to
    /// be observable. Never set from production code.
    nonisolated(unsafe) static var errorLoggerOverride: ErrorLogging?

    /// Test-only override for the annotations URL. When set, `annotationsURL`
    /// returns this value instead of deriving from `TPPConfiguration.mainFeedURL()`.
    /// CI runners boot with no signed-in library, so `mainFeedURL()` is nil and
    /// every annotation POST/GET path early-returns before hitting the
    /// HTTPStubURLProtocol handler. Tests that exercise the annotation network
    /// surface (e.g. CrossDeviceSyncE2ETests) inject their MockSyncBackend's
    /// base URL here. Never set from production code.
    nonisolated(unsafe) static var annotationsURLOverride: URL?

    // MARK: - Deletion-chain test join seam (STARVE-001)
    //
    // `deleteAllBookmarks` is deliberately fire-and-forget: it calls its
    // completion IMMEDIATELY and then runs a GET followed by N chained DELETEs
    // in the background, so a book return is never blocked. That makes it
    // untestable by waiting on the completion — tests used to poll a 3s
    // wall-clock deadline and assert on "whatever had happened by then", which
    // starves under parallel CI sim clones and is the STARVE-001 recurrence
    // class.
    //
    // Each `deleteAllBookmarks` call gets its OWN group counting that call's
    // in-flight chain (the GET, plus each DELETE it spawns), published here for
    // the test to join. Per-call rather than one process-wide group on purpose:
    // a shared group would accumulate imbalance across the whole test process,
    // so an unjoined call in one suite could hang an `await` in another. It is
    // only ever created under XCTest, so every production call site below is a
    // no-op `?.enter()` / `?.leave()` — the env-var gate (rather than
    // `#if DEBUG`) keeps the deletion path free of conditional compilation,
    // matching `AccountsManager._trackedCrawlTasks`.
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

    /// Synchronous lock-guarded read of the published chain. Split out of the
    /// `async` join seam below because `NSLock.lock()`/`.unlock()` are
    /// unavailable from an async context (Swift 6 forbids them even when the
    /// critical section never spans a suspension point) — same split as
    /// `AccountsManager._snapshotFirstRunTasksForTesting`.
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

        // Swift 6 `complete`: `Bookmark` is a Palace-owned non-Sendable protocol
        // (`protocol Bookmark: NSObject {}`), so a `[Bookmark]?` cannot cross the
        // `CheckedContinuation.resume(returning:)` Sendable boundary. Box the
        // single first bookmark we actually need. INVARIANT: the boxed value is
        // produced once inside the `getServerBookmarks` completion and read once
        // after the continuation resumes — no concurrent access.
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
                // Swift 6 `complete`: the double-resume guard (`didResume`) is
                // checked/set in this NON-`@Sendable` completion closure so the
                // `@Sendable` `DispatchQueue.main.async` hop below no longer
                // captures-and-mutates the local `var` (which the region-isolation
                // checker rejects). `response` (a `Sendable` struct) and
                // `continuation` (`Sendable`) are the only values that cross into
                // the main hop. Behavior is unchanged: resume still happens on the
                // main queue, exactly once.
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

        // Format bookmark for submission to server according to spec
        let bookmark = TPPBookmarkSpec(time: NSDate(),
                                       device: Self.currentAccountsManager.currentUserAccount.deviceID ?? "",
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
        //  - bookmark: key on the book AND the selector. Every bookmark is a
        //    distinct thing the patron created; keying on the book alone made
        //    two offline bookmarks in one title silently overwrite each other,
        //    and PP-4965 has already removed the error report for this path, so
        //    the loss would be invisible.
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
                // `logNetworkError` rather than `logError`, deliberately.
                //
                // The bare `logError(_:summary:metadata:)` overload hardcodes
                // `code: .ignore`, which would have quietly moved this bucket
                // OFF 902 (`.apiCall`) — to the raw NSError code for transport
                // failures and to 0 for server refusals — and flipped
                // `error_origin` from "server" to "unknown". Since the whole
                // plan is to re-measure what remains in the 902 bucket once
                // PP-4987 lands, that would have read as a fix while nothing
                // improved. `logNetworkError` keeps `.apiCall`, still routes
                // through `fixUpSummary` so transient conditions are split out
                // first, and takes the response so 400...599 classifies as
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
            // Behaviour deliberately unchanged by PP-4965: a bookmark POST that
            // fails still calls back with an empty response and reports nothing.
            // That silence is a real gap — bookmark failures produce no
            // telemetry at all — but fixing it changes behaviour patrons see,
            // so it is tracked separately rather than folded in here.
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
            // Behaviour deliberately unchanged by PP-4965: a bookmark POST that
            // fails still calls back with an empty response and reports nothing.
            // That silence is a real gap — bookmark failures produce no
            // telemetry at all — but fixing it changes behaviour patrons see,
            // so it is tracked separately rather than folded in here.
            guard case let .succeeded(id, timeStamp) = result else {
                completion(AnnotationResponse(serverId: nil, timeStamp: nil))
                return
            }
            completion(AnnotationResponse(serverId: id, timeStamp: timeStamp))
        }
    }

    /// How a POST to the annotations endpoint concluded.
    ///
    /// PP-4965: this exists because the previous `(Bool, String?, String?)`
    /// callback had nowhere to put "queued for retry" or a status code, so five
    /// very different outcomes all arrived at the caller as a bare `false`. The
    /// caller then reported every one of them as "Error posting annotation",
    /// which made that the largest error in the app while most of the traffic
    /// was patrons going through a tunnel.
    ///
    /// Keeping `queuedForRetry` distinct from `failed` is the whole point: a
    /// queued write has not been lost, and must not be reported as a failure.
    enum AnnotationPostResult {
        /// The server accepted the annotation. Both values may still be nil if
        /// the response body was missing or unparseable.
        case succeeded(annotationID: String?, timeStamp: String?)

        /// Transport failed, but the request was handed to the offline queue
        /// and will be retried. Delivery is pending, not lost — do NOT report
        /// this as an error.
        ///
        /// REACHABLE as of PP-4987. It was not when this case was written:
        /// the networking layer discarded the underlying transport error when
        /// no HTTP response arrived, substituting a generic no-response code
        /// absent from `NetworkQueue.StatusCodes`, so `willQueueOffline` could
        /// never be true. `TPPNetworkResponder` now passes that error through,
        /// so an offline write genuinely reaches the retry queue and this case
        /// carries real production traffic.
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

        // `isValidJSONObject` FIRST, deliberately. `data(withJSONObject:)`
        // RAISES an ObjC `NSInvalidArgumentException` for an unsupported type
        // rather than throwing a Swift error, so `try?` does not catch it and
        // the guard below never fired — an unserializable payload crashed the
        // app instead of taking the `.failed` path this code models. Not
        // reachable from today's three in-file callers (every value in
        // `dictionaryForJSONSerialization()` is a String), so this is defence
        // for the next caller, not a live bug fix. Found by writing the test
        // for the branch (PP-4965 review round 2).
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

                // Carry the response. `TPPNetworkResponder` synthesizes an
                // NSError for EVERY non-2xx and `TPPNetworkExecutor.POST`
                // forwards (nil, response, error) together, so this branch —
                // not the `else` below — is the one a server refusal actually
                // takes. Passing nil here dropped the status code before it
                // reached telemetry and left `TPPErrorOrigin.classify`'s
                // 400...599 arm unreachable from this call site, which made
                // "a refusal carries its status code" false in production
                // while two tests asserted it (PP-4965 review round 2).
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
                // The server's `/annotations/` endpoint returns ALL of
                // the user's annotations across every book they've ever
                // read, not just bookmarks for the requested book. Most
                // skipped items are filtered by `make()` for being
                // bookmarks for *other* books (`source != bookID`),
                // not parse failures. Logged at info, not warn, to
                // avoid alarming the support team — the number scales
                // with how much the user has read across the library.
                //
                // The cold-open latency from this endpoint dominates
                // bookmark load on books with many annotations: every
                // open re-downloads the same N-thousand-item payload
                // just to extract the few that match. A CM-side
                // per-book filter parameter would be the right fix.
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
        // Publish this call's chain BEFORE anything can return, so a test that
        // joins right after `completion()` can never observe a STALE previous
        // chain (or none at all, on the sync-gate early return) and conclude
        // "already settled". Today the tests are safe only because they are
        // `@MainActor` and this function runs to its tail synchronously —
        // publishing first makes that independent of the caller's isolation.
        // Every early return below must `leave()`. Nil (fully inert) outside XCTest.
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
        // WHY (3.2.3 build 490): 489 additionally deleted the AUDIOBOOK
        // `.readingProgress` on return, filed as "Cause 2" and described as a
        // 3.2.0 regression fix. Verification against the release tags showed it
        // is neither:
        //   • `deleteAllBookmarks` is BYTE-IDENTICAL in 3.1.0 and 3.2.0 — both
        //     query only `.bookmark` — so the audiobook position has never been
        //     deleted on return in any shipped build.
        //   • `TrackPosition+Annotations.swift` (the payload written to the
        //     server) has an EMPTY diff 3.1.0 → 3.2.0, and 3.1.0 already synced
        //     positions to the CM via `postListeningPosition`.
        //   • The cited tickets don't describe it: #18019 — the only genuine
        //     position report — was filed 2026-05-31 on 3.1.0, five weeks BEFORE
        //     3.2.0 shipped (07-08); #18449 is a download failure and #18468 a
        //     won't-play. What #18019 actually asks is that the position be
        //     CORRECT ("says ch1 p1 but it is not"), which is handled by
        //     `AudiobookSessionManager.validatedRemotePosition` — retained.
        //
        // Deleting a patron's place on return is therefore a NEW product
        // decision, not a regression fix, and it would be inconsistent on two
        // axes: audiobooks but not ebooks, and deliberate return but not loan
        // expiry (expiry never calls this method). Pending product sign-off it
        // stays out — a patron re-borrowing a 20-hour title keeps their place.
        //
        // NOTE: in 489 this deletion silently never executed anyway —
        // `AudioBookmark.create` lets the embedded `"annotationId": ""` that
        // Palace always writes shadow the real server id, so the parsed
        // bookmark had no server linkage and no DELETE was issued. Removing the
        // code makes the shipped behavior explicit instead of dependent on that
        // latent bug, which a future unrelated fix could otherwise wake up.
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
    /// of concrete type. Kept from 489 because it is strictly more correct than
    /// the historical `as? [TPPReadiumBookmark]` array cast for USER bookmarks:
    /// that cast silently dropped audiobook bookmarks wholesale. Returns `nil`
    /// for a bookmark with no server linkage or an unrecognised type (e.g. an
    /// unsynced `AudioBookmark`, or a PDF page bookmark — whose deletion
    /// behaviour is intentionally left unchanged).
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
                // Previously `guard let error … else { return }` — a nil response
                // AND nil error exited WITHOUT calling `completionHandler`. Every
                // caller then waits forever; the deletion-chain join seam turns
                // that silent gap into an unbounded test hang. A completion that
                // sometimes never fires is a bug for all callers, so report the
                // failure instead of vanishing.
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
        // Swift 6 `complete`: `TPPReadiumBookmark` is a Palace-owned non-Sendable
        // class, so the mutable `[TPPReadiumBookmark]` accumulators and the
        // per-upload `localBookmark` cannot be captured by the `@Sendable`
        // `DispatchQueue.main.async` / `uploadGroup.notify` closures as raw
        // values. Box the accumulators and the completion in a carrier whose
        // INVARIANT is that every mutation and every read happens on the main
        // queue: each upload's `append` runs inside `DispatchQueue.main.async`,
        // and the terminal read runs inside `notify(queue: DispatchQueue.main)`.
        // DispatchGroup serializes the two so no read races an in-flight append.
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

    /// State-machine-aware accessor used by Phase 2 (Bucket B) sync
    /// gates. Returns `nil` until the account is in `.detailsLoaded` —
    /// any other state (`.notLoaded`, `.basicInfoLoaded`, `.detailsLoading`,
    /// `.detailsFailed`, or the `.detailsEvicted` eviction-marker added by
    /// the swarm_51f248d5 enum split) yields nil. This preserves the
    /// nil-tolerance the legacy `account.details?` reads provided, but no
    /// longer races a partially-populated auth doc. Bookmark sync is a
    /// best-effort silent-failure path per the ADR, so nil during the
    /// loading window is correct (the next render after `.detailsLoaded`
    /// fires re-enables the sync paths).
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
/// Exists so `.queuedForRetry` is provable: without it, "the write reached the
/// queue" can only be verified by reading the code, and PP-4965 removes the
/// error report on the strength of that claim. `NetworkQueue` already has this
/// exact signature.
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

/// Sendable carrier for a single non-Sendable `Bookmark?` crossing the
/// `CheckedContinuation.resume(returning:)` Sendable boundary in
/// `syncReadingPosition`. `Bookmark` is a Palace-owned protocol
/// (`protocol Bookmark: NSObject {}`) and cannot be made `Sendable`.
/// INVARIANT — produced once in the `getServerBookmarks` completion, read once
/// after the continuation resumes.
private final class BookmarkBox: @unchecked Sendable {
    let bookmark: Bookmark?
    init(_ bookmark: Bookmark?) { self.bookmark = bookmark }
}

/// Sendable carrier for a single non-Sendable `TPPReadiumBookmark` handed to the
/// `@Sendable` `DispatchQueue.main.async` upload-completion in
/// `uploadLocalBookmarks`. `TPPReadiumBookmark` is a Palace-owned mutable class
/// (must not be made `Sendable`). INVARIANT — the boxed bookmark's
/// `annotationId` is mutated only on the main queue inside that completion.
/// Mirrors `ReadiumBookmarkBox` in `TPPReaderBookmarksBusinessLogic`.
private final class ReadiumBookmarkBox: @unchecked Sendable {
    let bookmark: TPPReadiumBookmark
    init(_ bookmark: TPPReadiumBookmark) { self.bookmark = bookmark }
}

/// Sendable carrier for the mutable `[TPPReadiumBookmark]` accumulators and the
/// non-Sendable completion in `uploadLocalBookmarks`. INVARIANT — `updated` and
/// `failed` are appended to only inside per-upload `DispatchQueue.main.async`
/// blocks and read only inside the `uploadGroup.notify(queue:
/// DispatchQueue.main)` terminal; all access is main-queue-confined and the
/// DispatchGroup serializes the terminal read after every append, so
/// `@unchecked Sendable` waives no real race.
private final class BookmarkUploadAccumulatorBox: @unchecked Sendable {
    var updated: [TPPReadiumBookmark] = []
    var failed: [TPPReadiumBookmark] = []
    let completion: ([TPPReadiumBookmark], [TPPReadiumBookmark]) -> Void
    init(completion: @escaping ([TPPReadiumBookmark], [TPPReadiumBookmark]) -> Void) {
        self.completion = completion
    }
}
