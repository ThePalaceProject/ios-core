//
//  AudiobookLoader.swift
//  Palace
//
//  Owned by AudiobookSessionManager. Builds an audiobook manager from a TPPBook:
//  token refresh, vendor-shape dispatch via the AudiobookVendorAdapter chain,
//  vendor key patching, manifest decoding, AudiobookFactory, DefaultAudiobookManager.
//  Returns a LoadedAudiobook; the session manager owns its lifetime.
//
//  Module D of swarm_5c8ddbd5 collapsed the pre-swarm implicit source-shape
//  branches (resolveManifestAndDecryptor + fetchOpenAccessManifest, ~150 LOC,
//  6-deep callbacks) into one linear chain:
//      let adapter = adapters.first(where: { $0.canHandle(book) })
//  Chain order: [LCP (#if LCP), LocalFile, BearerToken (MIME-gated), OpenAccess].
//  See `Vendors/Adapters+Production.swift` for the MIME gate + production wiring.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging
@preconcurrency import PalaceAudiobookToolkit

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
}

@MainActor
final class AudiobookLoader {

    private var isCancelled: Bool = false

    /// Adapter chain in priority order. First match wins. Tests inject a
    /// custom chain; production code uses `AudiobookLoader()` which builds
    /// the default chain via `Self.makeProductionAdapters()`.
    private let adapters: [AudiobookVendorAdapter]

    init(adapters: [AudiobookVendorAdapter]? = nil) {
        self.adapters = adapters ?? Self.makeProductionAdapters()
    }

    /// WS-3: re-fulfill loader. Bypasses `LocalFileAdapter` so an already-
    /// downloaded OverDrive book routes to `BearerTokenAdapter` for a FRESH
    /// fulfillment (fresh signed URLs) instead of replaying the stale on-disk
    /// manifest. Used only by the OverDrive expired-URL recovery path.
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
    /// `.manifestFetchFailed` — matches the pre-swarm "no default
    /// acquisition URL" failure mode.
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
        let accountsManager = AppContainer.production().accountsManager
        let userAccount = accountsManager.currentUserAccount
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

        AppContainer.production().networkExecutor.refreshTokenAndResume(task: nil, accountId: accountsManager.currentAccount?.uuid) { result in
            switch result {
            case .success:
                Log.info(#file, "✅ Token refresh successful - proceeding to open audiobook")
                completion(.success(()))
            case .failure(let error, _):
                Log.error(#file, "❌ Token refresh failed: \(error.localizedDescription)")
                completion(.failure(.tokenRefreshFailed(underlying: error)))
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

    // F-004 EXC_BREAKPOINT (Crashlytics, 3.0.0, distributor=Overdrive,
    // decryptor=nil, bearerToken present) enters here. Mockability seam
    // captured in `PalaceTests/Audiobooks/AudiobookLoaderFinalizeBuildTests`.
    private func finalizeBuild(
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

        let bookmarkLogic = AudiobookBookmarkBusinessLogic(book: book)
        manager.bookmarkDelegate = bookmarkLogic

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
            playbackModel: playbackModel
        )))
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
    // Two deterministic decisions extracted from inline branches so unit
    // tests can drive them without touching AppContainer.production() or
    // hitting the network. The predicates correspond to `cmp`-style mutation
    // points that previously survived every test because no isolated test
    // could reach them. Each has TRUE/FALSE bifurcation pinned in
    // AudiobookLoaderPredicateTests.

    /// True iff all three credential components a token refresh needs are
    /// present: a non-empty username, a non-empty PIN, and a non-nil
    /// tokenURL. Pure function over its primitive inputs — no AppContainer,
    /// no keychain. The branch on `tokenURL != nil` is the kill point for
    /// the corresponding mutation; tests provide a non-nil URL to assert
    /// the original returns `true` (mutant flips to `==`, returns `false`,
    /// test fails the mutant).
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
    /// `LocalFileAdapter` so an already-downloaded book is NOT served from its
    /// (possibly stale) on-disk manifest — used by the WS-3 OverDrive re-fulfill
    /// path so the book routes to `BearerTokenAdapter` for a FRESH fulfillment
    /// (fresh signed URLs), not a cached-manifest replay.
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

        // BearerTokenAdapter.canHandle is unconditional; the MIME gate
        // (BearerTokenMIMEGate) is Module D's chain placement gate.
        let bearerTokenAdapter = BearerTokenAdapter(
            network: manifestNetwork,
            manifestFetcher: ProductionBearerTokenManifestFetcher()
        )
        chain.append(BearerTokenMIMEGate(wrapped: bearerTokenAdapter))

        chain.append(OpenAccessAdapter(network: manifestNetwork))

        return chain
    }
}
