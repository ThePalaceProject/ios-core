//
//  AudiobookLoader.swift
//  Palace
//
//  Owned by AudiobookSessionManager. Builds an audiobook manager from a TPPBook:
//  token refresh, LCP pipeline (local file / license file / license re-download),
//  manifest retrieval (local / network / bearer-token), vendor key patching,
//  manifest decoding, AudiobookFactory, DefaultAudiobookNetworkService, and
//  DefaultAudiobookManager creation. Returns a LoadedAudiobook to the session
//  manager, which owns its lifetime and drives playback/UI/navigation.
//
//  Does NOT fire events, push navigation, start playback, or show error UI —
//  those are session-manager concerns.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
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
            self.resolveManifestAndDecryptor(for: book) { [weak self] resolveResult in
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

    // MARK: - Token refresh

    private func refreshTokenIfNeeded(for book: TPPBook, completion: @escaping (Result<Void, AudiobookLoadError>) -> Void) {
        let userAccount = AccountsManager.shared.currentUserAccount
        guard userAccount.authTokenHasExpired else {
            completion(.success(()))
            return
        }

        Log.info(#file, "🔄 Auth token expired for audiobook - refreshing before opening")
        logAccountDiagnostics(userAccount: userAccount, book: book)

        guard let username = userAccount.username, !username.isEmpty,
              let pin = userAccount.PIN, !pin.isEmpty,
              userAccount.authDefinition?.tokenURL != nil else {
            Log.error(#file, "Cannot refresh token: missing or empty credentials")
            completion(.failure(.missingCredentialsForTokenRefresh))
            return
        }
        _ = username // guard-bound but unused beyond the predicate check

        TPPNetworkExecutor.shared.refreshTokenAndResume(task: nil, accountId: AccountsManager.shared.currentAccount?.uuid) { result in
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

    // MARK: - Manifest + decryptor resolution

    private func resolveManifestAndDecryptor(
        for book: TPPBook,
        completion: @escaping (Result<([String: Any], DRMDecryptor?), AudiobookLoadError>) -> Void
    ) {
        Log.debug(#file, "🎵 [AUDIOBOOK] Attempting to present audiobook: \(book.title) (ID: \(book.identifier))")
        Log.debug(#file, "  Distributor: \(book.distributor ?? "nil")")

        #if LCP
        if LCPAudiobooks.canOpenBook(book) {
            Log.debug(#file, "  ✅ LCP audiobook detected")
            prepareLCPSource(for: book) { [weak self] sourceResult in
                guard let self else { completion(.failure(.cancelled)); return }
                switch sourceResult {
                case .success(let sourceURL):
                    self.loadLCPContent(book: book, lcpSourceURL: sourceURL, completion: completion)
                case .failure(let err):
                    completion(.failure(err))
                }
            }
            return
        } else {
            Log.debug(#file, "  Not an LCP audiobook")
        }
        #else
        Log.debug(#file, "  LCP not compiled in this build")
        #endif

        Log.debug(#file, "  Checking for local audiobook manifest...")
        if let url = AppContainer.production().downloadCenter.fileUrl(for: book.identifier),
           FileManager.default.fileExists(atPath: url.path) {
            Log.debug(#file, "  Local file exists at: \(url.path)")

            guard let data = try? Data(contentsOf: url) else {
                Log.error(#file, "  ❌ Failed to read local file data")
                completion(.failure(.manifestParseFailed))
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                Log.error(#file, "  ❌ Failed to parse local file as JSON")
                completion(.failure(.manifestParseFailed))
                return
            }

            Log.debug(#file, "  ✅ Successfully parsed local manifest JSON")

            if let fulfillURL = book.bearerTokenFulfillURL {
                Log.debug(#file, "  🔑 Bearer token book - refreshing token before playback")
                MyBooksSimplifiedBearerToken.refreshToken(from: fulfillURL) { newToken in
                    Task { @MainActor in
                        if let newToken = newToken {
                            Log.info(#file, "  ✅ Bearer token refreshed before playback")
                            book.bearerToken = newToken.accessToken
                        } else {
                            Log.warn(#file, "  ⚠️ Bearer token refresh failed - proceeding with existing token")
                        }
                        completion(.success((json, nil)))
                    }
                }
            } else {
                completion(.success((json, nil)))
            }
            return
        } else {
            Log.debug(#file, "  No local audiobook file found")
        }

        Log.debug(#file, "  → Fetching open access manifest from network...")
        fetchOpenAccessManifest(for: book) { json in
            guard let json else {
                Log.error(#file, "  ❌ Failed to fetch or parse open access manifest")
                completion(.failure(.manifestFetchFailed))
                return
            }
            Log.debug(#file, "  ✅ Successfully fetched and parsed open access manifest")
            completion(.success((json, nil)))
        }
    }

    #if LCP
    private func prepareLCPSource(
        for book: TPPBook,
        completion: @escaping (Result<URL, AudiobookLoadError>) -> Void
    ) {
        if let localURL = AppContainer.production().downloadCenter.fileUrl(for: book.identifier),
           FileManager.default.fileExists(atPath: localURL.path) {
            Log.debug(#file, "  → Using LOCAL LCP file: \(localURL.path)")
            completion(.success(localURL))
            return
        }

        if let license = licenseURL(forBookIdentifier: book.identifier) {
            Log.debug(#file, "  → Using LCP LICENSE file: \(license.path)")
            completion(.success(license))
            return
        }

        Log.info(#file, "  LCP audiobook with no local files - re-downloading LCP license from fulfill URL")
        redownloadLCPLicense(for: book, completion: completion)
    }

    private func loadLCPContent(
        book: TPPBook,
        lcpSourceURL: URL,
        completion: @escaping (Result<([String: Any], DRMDecryptor?), AudiobookLoadError>) -> Void
    ) {
        Log.debug(#file, "🔐 [LCP AUDIOBOOK] Building LCP-protected audiobook")
        Log.debug(#file, "  LCP source: \(lcpSourceURL.path)")

        guard let lcpAudiobooks = LCPAudiobooks(for: lcpSourceURL) else {
            Log.error(#file, "  ❌ Failed to create LCPAudiobooks instance from URL")
            completion(.failure(.lcpInstantiationFailed))
            return
        }
        Log.debug(#file, "  ✅ LCPAudiobooks instance created")

        if let cached = lcpAudiobooks.cachedContentDictionary() as? [String: Any] {
            Log.debug(#file, "  → Using CACHED content dictionary from LCP")
            completion(.success((cached, lcpAudiobooks)))
            return
        }

        Log.debug(#file, "  → Fetching content dictionary from LCP...")
        lcpAudiobooks.contentDictionary { dict, error in
            Task { @MainActor in
                if let error = error {
                    Log.error(#file, "  ❌ Error fetching LCP content dictionary: \(error.localizedDescription)")
                    completion(.failure(.lcpDecryptionFailed(underlying: error)))
                    return
                }
                guard let json = dict as? [String: Any] else {
                    Log.error(#file, "  ❌ LCP content dictionary is not a valid JSON dictionary")
                    completion(.failure(.lcpDecryptionFailed(underlying: nil)))
                    return
                }
                Log.debug(#file, "  ✅ Successfully retrieved LCP content dictionary")
                Log.debug(#file, "    Dictionary keys: \(json.keys.joined(separator: ", "))")
                completion(.success((json, lcpAudiobooks)))
            }
        }
    }

    private func redownloadLCPLicense(
        for book: TPPBook,
        completion: @escaping (Result<URL, AudiobookLoadError>) -> Void
    ) {
        guard let fulfillURL = book.defaultAcquisition?.hrefURL else {
            Log.error(#file, "  ❌ No fulfill URL for LCP audiobook re-download")
            completion(.failure(.missingFulfillURL))
            return
        }

        guard let contentURL = AppContainer.production().downloadCenter.fileUrl(for: book.identifier) else {
            Log.error(#file, "  ❌ Cannot determine content directory for LCP license")
            completion(.failure(.missingContentDirectory))
            return
        }

        let licenseFileURL = contentURL.deletingPathExtension().appendingPathExtension("lcpl")
        Log.info(#file, "  📡 Fetching LCP license from: \(fulfillURL.host ?? "unknown")")

        _ = TPPNetworkExecutor.shared.GET(fulfillURL) { data, response, error in
            if let error = error {
                Log.error(#file, "  ❌ Network error re-downloading LCP license: \(error.localizedDescription)")
                completion(.failure(.licenseDownloadFailed(underlying: error)))
                return
            }
            guard let data = data, !data.isEmpty else {
                Log.error(#file, "  ❌ No data received for LCP license re-download")
                completion(.failure(.licenseDownloadFailed(underlying: nil)))
                return
            }
            if let httpResponse = response as? HTTPURLResponse, !httpResponse.isSuccess() {
                Log.error(#file, "  ❌ LCP license re-download failed with HTTP \(httpResponse.statusCode)")
                completion(.failure(.licenseDownloadFailed(underlying: nil)))
                return
            }

            do {
                let directory = licenseFileURL.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                }
                try data.write(to: licenseFileURL, options: .atomic)
                Log.info(#file, "  ✅ LCP license saved to: \(licenseFileURL.lastPathComponent) (\(data.count) bytes)")
            } catch {
                Log.error(#file, "  ❌ Failed to save LCP license: \(error.localizedDescription)")
                completion(.failure(.licenseSaveFailed(underlying: error)))
                return
            }

            completion(.success(licenseFileURL))
        }
    }

    private func licenseURL(forBookIdentifier identifier: String) -> URL? {
        guard let contentURL = AppContainer.production().downloadCenter.fileUrl(for: identifier) else { return nil }
        let license = contentURL.deletingPathExtension().appendingPathExtension("lcpl")
        return FileManager.default.fileExists(atPath: license.path) ? license : nil
    }
    #endif

    // MARK: - Manifest network fetch (open access + bearer token)

    private func fetchOpenAccessManifest(for book: TPPBook, completion: @escaping ([String: Any]?) -> Void) {
        guard let url = book.defaultAcquisition?.hrefURL else {
            Log.error(#file, "  ❌ No default acquisition URL for fetching manifest")
            completion(nil)
            return
        }

        Log.debug(#file, "  📡 Fetching manifest from URL: \(url.absoluteString)")

        _ = TPPNetworkExecutor.shared.GET(url) { [weak self] data, response, error in
            guard let self else { completion(nil); return }
            if let error = error {
                Log.error(#file, "  ❌ Network error fetching manifest: \(error.localizedDescription)")
                completion(nil)
                return
            }
            guard let data = data else {
                Log.error(#file, "  ❌ No data received from manifest fetch")
                completion(nil)
                return
            }
            Log.debug(#file, "  ✅ Received \(data.count) bytes of manifest data")

            guard let json = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
                Log.error(#file, "  ❌ Failed to parse manifest data as JSON dictionary")
                if let httpResponse = response as? HTTPURLResponse {
                    Log.error(#file, "    HTTP status: \(httpResponse.statusCode)")
                    let isHTML = (httpResponse.allHeaderFields["Content-Type"] as? String)?.contains("html") == true
                    if isHTML {
                        Log.error(#file, "    ⚠️ Server returned HTML instead of JSON - likely a redirect to login or error page")
                    }
                }
                completion(nil)
                return
            }

            // The CM fulfill endpoint for bearer-token audiobooks returns a bearer
            // token response (with access_token/location), not the manifest itself.
            // Detect this and follow the two-step flow: fulfill -> bearer token -> manifest.
            if let bearerToken = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: json) {
                Log.info(#file, "  🔑 Received bearer token response from fulfill URL - fetching actual manifest")
                bearerToken.fulfillURL = url
                book.bearerToken = bearerToken.accessToken
                book.bearerTokenFulfillURL = url
                BookService.fetchManifestWithBearerToken(bearerToken, for: book, completion: completion)
                return
            }

            Log.debug(#file, "  ✅ Successfully parsed manifest JSON")
            completion(json)
        }
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
        Log.debug(#file, "  Has decryptor: \(decryptor != nil)")
        Log.debug(#file, "  Has bearer token: \(book.bearerToken != nil)")

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

        AudioBookVendorsHelper.updateVendorKey(book: jsonDict) { [weak self] error in
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
            let libraryId = AccountsManager.shared.currentAccount?.uuid,
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
}
