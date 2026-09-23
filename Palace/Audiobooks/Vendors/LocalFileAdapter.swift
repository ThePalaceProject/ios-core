//
//  LocalFileAdapter.swift
//  Palace
//
//  Vendor adapter for the "manifest JSON already on disk" audiobook source
//  shape. Module B of swarm_5c8ddbd5 (Audiobook Vendor Adapter Extraction).
//
//  Carve-out of `AudiobookLoader.resolveManifestAndDecryptor` lines 169-207
//  (pre-swarm). Behavior here is byte-for-byte equivalent: read local
//  manifest data from disk via the download center's `fileUrl(for:)`,
//  parse as JSON, and — if the book has a `bearerTokenFulfillURL` —
//  refresh the bearer token before completing.
//
//  Failure mapping:
//    - read fails / non-dict JSON → .manifestParseFailed
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging
@preconcurrency import PalaceAudiobookToolkit
import PalaceBookModel

/// Disk surface this adapter needs. Defined as a protocol so tests inject
/// an in-memory fake without touching the real filesystem.
protocol AudiobookFileReading: AnyObject {
    func fileExists(atPath path: String) -> Bool
    func data(at url: URL) throws -> Data
}

/// Bearer-token refresh seam — wraps `MyBooksSimplifiedBearerToken.refreshToken`
/// so adapter tests can drive both refresh-success and refresh-failure
/// branches without hitting URLSession.
protocol BearerTokenRefreshing {
    func refreshToken(
        from fulfillURL: URL,
        completion: @escaping @Sendable (MyBooksSimplifiedBearerToken?) -> Void
    )
}

/// Local-file audiobook adapter. Reads a downloaded manifest from disk
/// via the download center and parses it as JSON. Optionally refreshes
/// the bearer token before returning so playback uses a fresh token.
///
/// Constructor-style DI per CLAUDE.md — `downloadCenter`, `fileReader`,
/// and `tokenRefresher` are injected so tests cover the file-missing,
/// file-unreadable, valid-JSON, bearer-token-refresh-success, and
/// bearer-token-refresh-skipped paths without touching real disk or
/// AppContainer.production().
///
/// Not `@MainActor`-isolated at the class level — the protocol is not
/// MainActor (see contract notes in `AudiobookVendorAdapter.swift`).
/// Main-thread completion hops happen via `Task { @MainActor in }`.
final class LocalFileAdapter: AudiobookVendorAdapter {

    private let downloadCenter: MyBooksDownloadCenterProviding
    private let fileReader: AudiobookFileReading
    private let tokenRefresher: BearerTokenRefreshing

    init(
        downloadCenter: MyBooksDownloadCenterProviding,
        fileReader: AudiobookFileReading,
        tokenRefresher: BearerTokenRefreshing
    ) {
        self.downloadCenter = downloadCenter
        self.fileReader = fileReader
        self.tokenRefresher = tokenRefresher
    }

    /// `true` iff a manifest file is already on disk for this book. The
    /// chain places this adapter before the network adapters so a
    /// previously-downloaded audiobook never re-fetches.
    func canHandle(_ book: TPPBook) -> Bool {
        guard let url = downloadCenter.fileUrl(for: book.identifier) else {
            return false
        }
        return fileReader.fileExists(atPath: url.path)
    }

    func resolveManifest(
        for book: TPPBook,
        completion: @escaping (Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError>) -> Void
    ) {
        guard let url = downloadCenter.fileUrl(for: book.identifier),
              fileReader.fileExists(atPath: url.path) else {
            Log.error(#file, "  ❌ LocalFileAdapter invoked without a local file")
            completion(.failure(.manifestParseFailed))
            return
        }

        Log.debug(#file, "  Local file exists at: \(url.path)")

        let data: Data
        do {
            data = try fileReader.data(at: url)
        } catch {
            Log.error(#file, "  ❌ Failed to read local file data: \(error.localizedDescription)")
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
            // Box the non-`@Sendable` completion AND the parsed `[String: Any]`
            // manifest so both can cross the refresh callback →
            // `Task { @MainActor in }` hop without forcing `@Sendable` onto the
            // `AudiobookVendorAdapter` protocol. `[String: Any]` is not
            // `Sendable` (it holds `Any` existentials), so it needs its own
            // carrier. See `AudiobookAdapterCompletionBox` / `ManifestJSONBox`.
            let completionBox = AudiobookAdapterCompletionBox(completion)
            let jsonBox = ManifestJSONBox(json)
            tokenRefresher.refreshToken(from: fulfillURL) { newToken in
                Task { @MainActor in
                    if let newToken = newToken {
                        Log.info(#file, "  ✅ Bearer token refreshed before playback")
                        book.bearerToken = newToken.accessToken
                    } else {
                        Log.warn(#file, "  ⚠️ Bearer token refresh failed - proceeding with existing token")
                    }
                    completionBox.fire(.success((json: jsonBox.value, decryptor: nil)))
                }
            }
        } else {
            completion(.success((json: json, decryptor: nil)))
        }
    }
}
