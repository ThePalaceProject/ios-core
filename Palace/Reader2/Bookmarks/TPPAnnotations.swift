import UIKit
import ReadiumShared
import PalaceLogging

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

    /// Test-only override for the annotations URL. When set, `annotationsURL`
    /// returns this value instead of deriving from `TPPConfiguration.mainFeedURL()`.
    /// CI runners boot with no signed-in library, so `mainFeedURL()` is nil and
    /// every annotation POST/GET path early-returns before hitting the
    /// HTTPStubURLProtocol handler. Tests that exercise the annotation network
    /// surface (e.g. CrossDeviceSyncE2ETests) inject their MockSyncBackend's
    /// base URL here. Never set from production code.
    nonisolated(unsafe) static var annotationsURLOverride: URL?

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
                DispatchQueue.main.async {
                    guard !didResume else { return }
                    didResume = true

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

        postAnnotation(forBook: bookID, withAnnotationURL: annotationsURL, withParameters: parameters, queueOffline: true) { (success, id, timeStamp) in
            guard success else {
                Log.warn(#file, "Annotation POST failed for \(bookID)")
                TPPErrorLogger.logError(withCode: .apiCall,
                                        summary: "Error posting annotation",
                                        metadata: [
                                            "bookID": bookID,
                                            "annotationID": id ?? "N/A",
                                            "annotationURL": annotationsURL,
                                            "motivation": motivation.rawValue])
                completion?(nil)
                return
            }

            Log.debug(#file, "Successfully saved Reading Position to server: \(selectorValue)")
            completion?(AnnotationResponse(serverId: id, timeStamp: timeStamp))
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

        postAnnotation(forBook: bookID, withAnnotationURL: annotationsURL, withParameters: parameters, queueOffline: false) { (_, id, timeStamp) in
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

        postAnnotation(forBook: bookID, withAnnotationURL: annotationsURL, withParameters: parameters, queueOffline: false) { (_, id, timeStamp) in
            completion(AnnotationResponse(serverId: id, timeStamp: timeStamp))
        }
    }

    /// Serializes the `parameters` into JSON and POSTs them to the server.
    static func postAnnotation(forBook bookID: String,
                              withAnnotationURL url: URL,
                              withParameters parameters: [String: Any],
                              timeout: TimeInterval = TPPDefaultRequestTimeout,
                              queueOffline: Bool,
                              _ completionHandler: @escaping (_ success: Bool, _ annotationID: String?, _ timeStamp: String?) -> Void) {

        guard let jsonData = try? JSONSerialization.data(withJSONObject: parameters, options: [.prettyPrinted]) else {
            Log.error(#file, "Network request abandoned. Could not create JSON from given parameters.")
            completionHandler(false, nil, nil)
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
                    self.addToOfflineQueue(bookID, url, parameters)
                }

                completionHandler(false, nil, nil)
                return
            }
            guard let statusCode = (response as? HTTPURLResponse)?.statusCode else {
                Log.error(#file, "Annotation POST error: No response received from server")
                completionHandler(false, nil, nil)
                return
            }

            if statusCode == 200 {
                Log.debug(#file, "Annotation POST: Success 200.")
                let serverAnnotationID = annotationID(fromNetworkData: data)
                let timeStamp = timeStamp(fromNetworkData: data)
                completionHandler(true, serverAnnotationID, timeStamp)
            } else {
                Log.error(#file, "Annotation POST: Response Error. Status Code: \(statusCode)")
                completionHandler(false, nil, nil)
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
        // Call completion immediately - never block book returns
        completion()

        // Fire-and-forget: delete bookmarks in background
        guard syncIsPossibleAndPermitted() else { return }

        getServerBookmarks(forBook: book, atURL: book.annotationsURL, motivation: .bookmark) { bookmarks in
            guard let readiumBookmarks = bookmarks as? [TPPReadiumBookmark], !readiumBookmarks.isEmpty else {
                return
            }

            for bookmark in readiumBookmarks {
                guard let annotationId = bookmark.annotationId else { continue }
                deleteBookmark(annotationId: annotationId) { _ in }
            }
        }
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
                guard let error = error as NSError? else { return }
                Log.error(#file, "DELETE bookmark Request Failed with Error Code: \(error.code). Description: \(error.localizedDescription)")
                completionHandler(false)
            }
        }

        task?.resume()
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
        AppContainer.production().networkQueue.addRequest(libraryID, bookID, url, .POST, parameterData, headers)
    }
}

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
