//
//  AudiobookLoader.swift
//  Palace
//
//  Owned by AudiobookSessionManager. Builds an audiobook manager from a TPPBook:
//  token refresh, vendor-shape dispatch via the AudiobookVendorAdapter chain,
//  vendor key patching, manifest decoding, AudiobookFactory, DefaultAudiobookManager.
//  Returns a LoadedAudiobook; the session manager owns its lifetime. Source
//  dispatch is the first adapter whose `canHandle` is true, in order
//  [LCP (#if LCP), LocalFile, BearerToken (MIME-gated), OpenAccess].
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging
@preconcurrency import PalaceAudiobookToolkit
import PalaceBookModel
import PalaceUtilities

/// Errors produced by AudiobookLoader during audiobook preparation.
enum AudiobookLoadError: Error {
    case cancelled
    case tokenRefreshFailed(underlying: Error?)
    case missingCredentialsForTokenRefresh
    case lcpNotAvailable
    case lcpInstantiationFailed
    case lcpDecryptionFailed(underlying: Error?)
    case licenseDownloadFailed(underlying: Error?)
    case licenseSaveFailed(underlying: Error)
    case missingFulfillURL
    case missingContentDirectory
    case manifestFetchFailed
    case manifestParseFailed
    case manifestSerializationFailed
    case vendorKeyUpdateFailed(underlying: NSError)
    case manifestDecodingFailed(underlying: Error)
    case factoryFailed(manifestType: String?)
}

/// The result of successfully loading an audiobook.
struct LoadedAudiobook {
    let manager: AudiobookManager
    let audiobook: Audiobook
    let decryptor: DRMDecryptor?
    let playbackModel: AudiobookPlaybackModel
    /// PP-4963 position instrumentation for this session.
    ///
    /// A handle, not the owner: `AudiobookBookmarkBusinessLogic` (retained by
    /// `AudiobookManager.bookmarkDelegate`) keeps it alive. `bind` destructures
    /// and drops this struct, so ownership here would deallocate the recorder.
    let positionTrace: AudiobookPositionTraceRecorder
}

/// The slice of `AudiobookManager` the PP-4963 position trace joins to.
///
/// A protocol so `makePositionTrace` can be tested without
/// `DefaultAudiobookManager`, whose `init` starts timers and remote-command
/// observers. `AudiobookManager` declares `bookmarkDelegate` get-only, so it
/// cannot serve either.
@MainActor
protocol AudiobookPositionTraceHost: AnyObject {
    var bookmarkDelegate: AudiobookBookmarkDelegate? { get set }
    var audiobook: Audiobook { get }
}

extension DefaultAudiobookManager: @MainActor AudiobookPositionTraceHost {}

@MainActor
final class AudiobookLoader {

    private var isCancelled: Bool = false

    /// Adapter chain in priority order. First match wins. Tests inject a
    /// custom chain; production code uses `AudiobookLoader()` which builds
    /// the default chain via `Self.makeProductionAdapters()`.
    private let adapters: [AudiobookVendorAdapter]

    /// The account whose token gates `load` (PP-5295). Called once per `load`,
    /// not at init, so the account current at open time is the one checked.
    /// Tests inject an account so the gate does not depend on whatever the
    /// shared container's current account holds.
    private let currentUserAccount: () -> TPPUserAccount

    init(
        adapters: [AudiobookVendorAdapter]? = nil,
        currentUserAccount: (() -> TPPUserAccount)? = nil
    ) {
        self.adapters = adapters ?? Self.makeProductionAdapters()
        self.currentUserAccount = currentUserAccount
            ?? { AppContainer.production().accountsManager.currentUserAccount }
    }

    /// Re-fulfill loader (PP-4800). Bypasses `LocalFileAdapter` so an already-
    /// downloaded book gets a fresh fulfillment (fresh signed URLs) instead of
    /// replaying the stale on-disk manifest.
    convenience init(forceRefulfill: Bool) {
        self.init(adapters: forceRefulfill ? Self.makeProductionAdapters(excludeLocalFile: true) : nil)
    }

    // MARK: - Public API

    /// Load an audiobook end-to-end. Calls completion on the main thread.
    /// The loader is single-use per instance; create a new loader per open.
    func load(_ book: TPPBook, completion: @escaping (Result<LoadedAudiobook, AudiobookLoadError>) -> Void) {
        let finish: (Result<LoadedAudiobook, AudiobookLoadError>) -> Void = { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if self.isCancelled {
                    completion(.failure(.cancelled))
                    return
                }
                completion(result)
            }
        }

        refreshTokenIfNeeded(for: book) { [weak self] tokenResult in
            guard let self else { finish(.failure(.cancelled)); return }
            if case .failure(let err) = tokenResult {
                finish(.failure(err))
                return
            }
            self.resolveSource(for: book) { [weak self] resolveResult in
                guard let self else { finish(.failure(.cancelled)); return }
                switch resolveResult {
                case .success(let (json, decryptor)):
                    self.build(book: book, json: json, decryptor: decryptor, completion: finish)
                case .failure(let err):
                    finish(.failure(err))
                }
            }
        }
    }

    /// Mark this loader as cancelled. Any pending completion will resolve with .cancelled.
    func cancel() {
        isCancelled = true
    }

    // MARK: - Adapter chain dispatch

    /// Run the adapter chain. First `canHandle == true` wins; the picked
    /// adapter owns the result. If no adapter matches, surface
    /// `.manifestFetchFailed`.
    private func resolveSource(
        for book: TPPBook,
        completion: @escaping (Result<([String: Any], DRMDecryptor?), AudiobookLoadError>) -> Void
    ) {
        Log.debug(#file, "🎵 [AUDIOBOOK] Resolving source for: \(book.title) (ID: \(book.identifier))")
        Log.debug(#file, "  Distributor: \(book.distributor ?? "nil")")

        guard let adapter = adapters.first(where: { $0.canHandle(book) }) else {
            Log.error(#file, "  ❌ No adapter claimed the book — surfacing .manifestFetchFailed")
            completion(.failure(.manifestFetchFailed))
            return
        }

        Log.debug(#file, "  → Dispatching to \(type(of: adapter))")
        adapter.resolveManifest(for: book) { result in
            switch result {
            case .success(let value):
                completion(.success((value.json, value.decryptor)))
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    // MARK: - Token refresh

    private func refreshTokenIfNeeded(for book: TPPBook, completion: @escaping (Result<Void, AudiobookLoadError>) -> Void) {
        let userAccount = currentUserAccount()
        guard userAccount.authTokenHasExpired else {
            completion(.success(()))
            return
        }

        Log.info(#file, "🔄 Auth token expired for audiobook - refreshing before opening")
        logAccountDiagnostics(userAccount: userAccount, book: book)

        guard Self.hasRefreshableCredentials(
            username: userAccount.username,
            pin: userAccount.PIN,
            tokenURL: userAccount.authDefinition?.tokenURL
        ) else {
            Log.error(#file, "Cannot refresh token: missing or empty credentials")
            completion(.failure(.missingCredentialsForTokenRefresh))
            return
        }

        let container = AppContainer.production()
        let accountId = container.accountsManager.currentAccount?.uuid
        container.networkExecutor.refreshTokenAndResume(task: nil, accountId: accountId) { result in
            switch result {
            case .success:
                Log.info(#file, "✅ Token refresh successful - proceeding to open audiobook")
                completion(.success(()))
            case .failure(let error, _):
                // PP-4542: another refresh (usually the launch-time proactive
                // refresh) holds the single-flight slot, and
                // refreshTokenAndResume(task: nil) fails immediately rather than
                // queueing. Opening an audiobook right after launch hit this
                // (Crashlytics 27f5746). Wait for the in-flight refresh instead.
                if Self.isRefreshInProgressError(error) {
                    Log.info(#file, "⏳ A token refresh is already in progress — awaiting it before opening audiobook")
                    Self.awaitTokenReady { becameValid in
                        if becameValid {
                            Log.info(#file, "✅ In-flight token refresh completed — proceeding to open audiobook")
                            completion(.success(()))
                        } else {
                            Log.error(#file, "❌ Timed out awaiting in-flight token refresh")
                            completion(.failure(.tokenRefreshFailed(underlying: error)))
                        }
                    }
                    return
                }
                Log.error(#file, "❌ Token refresh failed: \(error.localizedDescription)")
                completion(.failure(.tokenRefreshFailed(underlying: error)))
            }
        }
    }

    /// True when `error` is the "Token refresh in progress" signal from
    /// `TPPNetworkExecutor.refreshTokenAndResume(task:)` — i.e. another refresh
    /// already owns the single-flight slot. Matched on the message (not the
    /// code) because `invalidCredentials` is overloaded for several token
    /// failures; only this one is safe to wait on.
    nonisolated static func isRefreshInProgressError(_ error: Error) -> Bool {
        (error as NSError).localizedDescription.localizedCaseInsensitiveContains("token refresh in progress")
    }

    /// Polls the *current* account's token state until a concurrently-running
    /// refresh populates a valid (unexpired) token, or `timeout` elapses.
    /// Re-reads `currentUserAccount` each tick so a mid-flight account-object
    /// swap can't strand us on a stale instance. Bounded so a stuck refresh
    /// cannot hang the open; on timeout the caller surfaces the original error.
    nonisolated static func awaitTokenReady(
        timeout: TimeInterval = 10.0,
        pollInterval: TimeInterval = 0.15,
        completion: @escaping (Bool) -> Void
    ) {
        // The non-`@Sendable` completion is boxed to cross into the poll Task;
        // it fires exactly once (ready XOR timeout).
        let completionBox = TokenReadyCompletionBox(completion)
        Task {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                if !AppContainer.production().accountsManager.currentUserAccount.authTokenHasExpired {
                    completionBox.fire(true)
                    return
                }
                if Date() >= deadline {
                    completionBox.fire(false)
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(max(0, pollInterval) * 1_000_000_000))
            }
        }
    }

    private func logAccountDiagnostics(userAccount: TPPUserAccount, book: TPPBook) {
        let authDef = userAccount.authDefinition
        let authType = authDef?.authType.rawValue ?? "none"
        let authState = userAccount.authState
        Log.info(#file, "  📋 Account diagnostics for audiobook open:")
        Log.info(#file, "    authType=\(authType), authState=\(authState)")
        Log.info(#file, "    hasBarcode=\(userAccount.barcode != nil), hasPin=\(userAccount.PIN != nil), hasToken=\(userAccount.authToken != nil), hasTokenURL=\(authDef?.tokenURL != nil)")
        Log.info(#file, "    tokenExpired=\(userAccount.authTokenHasExpired), tokenNearExpiry=\(userAccount.authTokenNearExpiry)")
        Log.info(#file, "    book.distributor=\(book.distributor ?? "nil"), book.hasBearerToken=\(book.bearerToken != nil)")
    }

    // MARK: - Build pipeline

    private func build(
        book: TPPBook,
        json: [String: Any],
        decryptor: DRMDecryptor?,
        completion: @escaping (Result<LoadedAudiobook, AudiobookLoadError>) -> Void
    ) {
        Log.debug(#file, "🏗️ [AUDIOBOOK FACTORY] Building audiobook from manifest")
        Log.debug(#file, "  Book: \(book.title) (ID: \(book.identifier))")
        Log.debug(#file, "  Has decryptor: \(decryptor != nil), Has bearer token: \(book.bearerToken != nil)")

        // Pre-serialize JSON on the calling thread to avoid capturing the
        // [String: Any] dictionary (which contains reference-typed values)
        // across an async boundary. Capturing `Any` existentials in closures
        // was causing EXC_BREAKPOINT in block_destroy_helper.
        var jsonDict = json
        jsonDict["id"] = book.identifier

        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonDict, options: []) else {
            Log.error(#file, "  ❌ Failed to serialize JSON dictionary to Data")
            completion(.failure(.manifestSerializationFailed))
            return
        }

        // Resolve the DRM vendor synchronously so the [String: Any] dictionary
        // never crosses an async boundary. Crashlytics 7bf923ee shows
        // block_destroy_helper EXC_BREAKPOINT crashes on cantook DRM books even
        // after the jsonData pre-serialization above; passing `jsonDict` to the
        // @objc round-trip in `updateVendorKey` was a second existential-capture
        // path. For non-DRM books we now skip the async hop entirely.
        let drmVendor = AudioBookVendorsHelper.feedbookVendor(for: jsonDict)

        guard let drmVendor else {
            if isCancelled {
                completion(.failure(.cancelled))
                return
            }
            finalizeBuild(book: book, jsonData: jsonData, decryptor: decryptor, completion: completion)
            return
        }

        AudioBookVendorsHelper.updateDrmCertificate(for: drmVendor) { [weak self] error in
            Task { @MainActor in
                guard let self else { completion(.failure(.cancelled)); return }
                if self.isCancelled {
                    completion(.failure(.cancelled))
                    return
                }
                if let error = error {
                    Log.error(#file, "  ❌ Vendor completion failed with error: \(error.localizedDescription)")
                    completion(.failure(.vendorKeyUpdateFailed(underlying: error)))
                    return
                }

                self.finalizeBuild(book: book, jsonData: jsonData, decryptor: decryptor, completion: completion)
            }
        }
    }

    // `internal` so tests can drive decode → factory → zero-track guard
    // (PP-4768); the guard returns before the AppContainer.production() reads.
    func finalizeBuild(
        book: TPPBook,
        jsonData: Data,
        decryptor: DRMDecryptor?,
        completion: @escaping (Result<LoadedAudiobook, AudiobookLoadError>) -> Void
    ) {
        Log.debug(#file, "  Creating audiobook with bearerToken: '\(book.bearerToken ?? "nil")'")
        Log.debug(#file, "  JSON data size: \(jsonData.count) bytes")

        let manifest: Manifest
        do {
            manifest = try Manifest.customDecoder().decode(Manifest.self, from: jsonData)
        } catch {
            Log.error(#file, "  ❌ Failed to decode Manifest from JSON: \(error)")
            if let decodingError = error as? DecodingError {
                logDecodingError(decodingError)
            }
            completion(.failure(.manifestDecodingFailed(underlying: error)))
            return
        }

        Log.debug(#file, "  ✅ Manifest decoded successfully")
        Log.debug(#file, "    Manifest metadata: \(manifest.metadata?.title ?? "no title")")

        guard let audiobook = AudiobookFactory.audiobook(
            for: manifest,
            bookIdentifier: book.identifier,
            decryptor: decryptor,
            token: book.bearerToken,
            fulfillURL: book.bearerTokenFulfillURL
        ) else {
            Log.error(#file, "  ❌ AudiobookFactory failed to create audiobook")
            completion(.failure(.factoryFailed(manifestType: manifest.metadata?.type)))
            return
        }

        // PP-4768: a manifest carrying only `contentlinks` can decode yet yield
        // no playable tracks, and `Audiobook.init?` does not fail on empty
        // tracks. The toolkit player would later trap on a `[0]` subscript, so
        // reject a trackless audiobook through `.factoryFailed`.
        guard !audiobook.tableOfContents.allTracks.isEmpty else {
            Log.error(#file, "  ❌ Factory produced a zero-track audiobook — rejecting to avoid a trackless player")
            completion(.failure(.factoryFailed(manifestType: manifest.metadata?.type)))
            return
        }

        Log.debug(#file, "  ✅ Audiobook created successfully by factory")

        let metadata = AudiobookMetadata(title: book.title, authors: [book.authors ?? ""])
        var timeTracker: AudiobookTimeTracker?
        if
            let libraryId = AppContainer.production().accountsManager.currentAccount?.uuid,
            let url = book.timeTrackingURL {
            timeTracker = AudiobookTimeTracker(libraryId: libraryId, bookId: book.identifier, timeTrackingUrl: url)
        }

        let networkService = DefaultAudiobookNetworkService(
            tracks: audiobook.tableOfContents.allTracks,
            decryptor: decryptor
        )
        networkService.downloadOnlyOnWiFi = AppContainer.production().settings.downloadOnlyOnWiFi

        let manager = DefaultAudiobookManager(
            metadata: metadata,
            audiobook: audiobook,
            networkService: networkService,
            playbackTrackerDelegate: timeTracker
        )

        // PP-4712: apply the patron's global skip-interval choices to this
        // manager so subsequently opened audiobooks pick up the current setting.
        let skipSettings = AudiobookSkipIntervalSettings()
        manager.skipForwardInterval = skipSettings.forwardTimeInterval
        manager.skipBackInterval = skipSettings.backTimeInterval

        // PP-4963: watch the save path against the playback clock, so a locked
        // listen that stops saving becomes an event instead of an absence.
        let positionTrace = makePositionTrace(book: book, manager: manager)

        manager.playbackCompletionHandler = { [weak book, weak manager] in
            guard let book = book, let manager = manager else { return }
            if let firstTrack = manager.audiobook.tableOfContents.allTracks.first {
                let beginningPosition = TrackPosition(
                    track: firstTrack,
                    timestamp: 0.0,
                    tracks: manager.audiobook.tableOfContents.tracks
                )
                manager.saveLocation(beginningPosition)
            }
            BookDetailViewModel.presentEndOfBookAlert(for: book, downloadCenter: AppContainer.production().downloadCenter)
        }

        let playbackModel = AudiobookPlaybackModel(audiobookManager: manager)

        completion(.success(LoadedAudiobook(
            manager: manager,
            audiobook: audiobook,
            decryptor: decryptor,
            playbackModel: playbackModel,
            positionTrace: positionTrace
        )))
    }

    /// Builds the PP-4963 recorder and joins it to the session graph. Separate
    /// from `finalizeBuild` so the wiring is testable without
    /// `AppContainer.production()`.
    ///
    /// Three joins, in the order they have to happen:
    ///
    /// 1. the recorder is constructed for this book;
    /// 2. `AudiobookBookmarkBusinessLogic` takes it as a `let` and becomes
    ///    `manager.bookmarkDelegate`, which is the ONLY thing that keeps the
    ///    recorder alive for the session — the manager retains the delegate and
    ///    `AudiobookSessionManager` retains the manager, while `LoadedAudiobook`
    ///    is a struct `bind` destructures and drops;
    /// 3. the recorder subscribes to the PLAYER's own position signal and to
    ///    foreground return.
    ///
    /// - Parameter recorder: nil in production (one is built for `book`); tests
    ///   inject one they can observe.
    /// - Parameter notificationCenter: injectable so a test can drive the
    ///   foreground subscription without a global `didBecomeActiveNotification`
    ///   post, which would wake other app observers.
    @discardableResult
    func makePositionTrace(
        book: TPPBook,
        manager: AudiobookPositionTraceHost,
        recorder: AudiobookPositionTraceRecorder? = nil,
        notificationCenter: NotificationCenter = .default
    ) -> AudiobookPositionTraceRecorder {
        let positionTrace = recorder ?? AudiobookPositionTraceRecorder(bookID: book.identifier)
        let bookmarkLogic = AudiobookBookmarkBusinessLogic(book: book, positionTrace: positionTrace)
        manager.bookmarkDelegate = bookmarkLogic
        // `observe(player:)` rather than the publisher form: the liveness
        // signal MUST be the playback clock's, and passing the player makes
        // anything runloop-fed unrepresentable here.
        positionTrace.observe(player: manager.audiobook.player,
                              notificationCenter: notificationCenter)
        return positionTrace
    }

    private func logDecodingError(_ decodingError: DecodingError) {
        switch decodingError {
        case .keyNotFound(let key, let context):
            Log.error(#file, "    Missing key: '\(key.stringValue)' at path: \(context.codingPath.map { $0.stringValue }.joined(separator: " → "))")
        case .typeMismatch(let type, let context):
            Log.error(#file, "    Type mismatch: expected \(type) at path: \(context.codingPath.map { $0.stringValue }.joined(separator: " → "))")
            Log.error(#file, "    Debug description: \(context.debugDescription)")
        case .valueNotFound(let type, let context):
            Log.error(#file, "    Value not found: \(type) at path: \(context.codingPath.map { $0.stringValue }.joined(separator: " → "))")
        case .dataCorrupted(let context):
            Log.error(#file, "    Data corrupted at path: \(context.codingPath.map { $0.stringValue }.joined(separator: " → "))")
            Log.error(#file, "    Description: \(context.debugDescription)")
        @unknown default:
            Log.error(#file, "    Unknown decoding error")
        }
    }

    // MARK: - Testable predicates
    //
    // Pure decisions extracted so tests can drive them without
    // AppContainer.production() or the network (AudiobookLoaderPredicateTests).

    /// True iff all three credential components a token refresh needs are
    /// present: a non-empty username, a non-empty PIN, and a non-nil tokenURL.
    nonisolated static func hasRefreshableCredentials(username: String?, pin: String?, tokenURL: URL?) -> Bool {
        guard let username, !username.isEmpty else { return false }
        guard let pin, !pin.isEmpty else { return false }
        guard tokenURL != nil else { return false }
        return true
    }

    /// True iff `response` advertises an HTML body via its `Content-Type`
    /// header. Used to distinguish "manifest endpoint returned a login
    /// redirect page" from "manifest endpoint returned malformed JSON" —
    /// the two failures have the same downstream completion (nil) but
    /// log differently for diagnosis.
    nonisolated static func looksLikeHTMLResponse(_ response: HTTPURLResponse) -> Bool {
        return (response.allHeaderFields["Content-Type"] as? String)?.contains("html") == true
    }

    // MARK: - Production adapter chain wiring
    //
    // Default chain pulled from AppContainer.production(); tests bypass
    // with the `adapters:` init. Order: LCP > LocalFile > BearerToken
    // (MIME-gated — see `BearerTokenMIMEGate` in Adapters+Production.swift)
    // > OpenAccess. OpenAccess keeps in-band wrapper auto-detection as a
    // defensive fallback for CM fulfill responses missing the wrapper MIME.

    /// Builds the production adapter chain. `excludeLocalFile` drops the
    /// `LocalFileAdapter` so the OverDrive re-fulfill path gets a fresh
    /// fulfillment instead of the possibly stale on-disk manifest.
    private static func makeProductionAdapters(excludeLocalFile: Bool = false) -> [AudiobookVendorAdapter] {
        let downloadCenter = AppContainer.production().downloadCenter
        let networkExecutor = AppContainer.production().networkExecutor
        let manifestNetwork = ProductionAudiobookManifestFetcher(executor: networkExecutor)

        var chain: [AudiobookVendorAdapter] = []

        #if LCP
        chain.append(LCPAdapter(
            downloadCenter: downloadCenter,
            networkExecutor: networkExecutor
        ))
        #endif

        if !excludeLocalFile {
            chain.append(LocalFileAdapter(
                downloadCenter: downloadCenter,
                fileReader: ProductionAudiobookFileReader(),
                tokenRefresher: ProductionBearerTokenRefresher()
            ))
        }

        // BearerTokenAdapter.canHandle is unconditional; BearerTokenMIMEGate
        // decides whether it is placed in the chain.
        let bearerTokenAdapter = BearerTokenAdapter(
            network: manifestNetwork,
            manifestFetcher: ProductionBearerTokenManifestFetcher()
        )
        chain.append(BearerTokenMIMEGate(wrapped: bearerTokenAdapter))

        // OpenAccessAdapter is the fallback for books the MIME gate does not
        // claim; it is given the bearer-token second-leg fetcher so it can
        // recover OverDrive / Unlimited Listens loans whose bearer-token MIME
        // is nested in the indirectAcquisition chain (PP-4631).
        chain.append(OpenAccessAdapter(
            network: manifestNetwork,
            bearerTokenManifestFetcher: ProductionBearerTokenManifestFetcher()
        ))

        return chain
    }
}

/// `Sendable` carrier for `awaitTokenReady`'s non-`@Sendable` completion so it
/// can cross into the poll `Task` without forcing `@Sendable` onto the
/// `awaitTokenReady` signature (which would ripple to its call site).
///
/// - Sendable invariant: the poll loop calls `fire(_:)` exactly once
///   (token-ready XOR timeout) from a single Task, never concurrently.
private struct TokenReadyCompletionBox: @unchecked Sendable {
    private let completion: (Bool) -> Void

    init(_ completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }

    func fire(_ becameValid: Bool) {
        completion(becameValid)
    }
}
