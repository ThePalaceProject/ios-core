//
//  LocalFileAdapter.swift
//  Palace
//
//  Vendor adapter for a manifest already on disk: reads it via the download
//  center's `fileUrl(for:)`, parses it, and refreshes the bearer token first
//  when the book has a `bearerTokenFulfillURL`.
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
///
/// `@MainActor` and `async` for the reason recorded on `AudiobookVendorAdapter`
/// (PP-5301).
@MainActor
protocol BearerTokenRefreshing {
    func refreshToken(from fulfillURL: URL) async -> MyBooksSimplifiedBearerToken?
}

/// Local-file audiobook adapter. Reads a downloaded manifest from disk
/// via the download center and parses it as JSON. Optionally refreshes
/// the bearer token before returning so playback uses a fresh token.
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
        for book: TPPBook
    ) async -> Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError> {
        guard let url = downloadCenter.fileUrl(for: book.identifier),
              fileReader.fileExists(atPath: url.path) else {
            Log.error(#file, "  ❌ LocalFileAdapter invoked without a local file")
            return .failure(.manifestParseFailed)
        }

        Log.debug(#file, "  Local file exists at: \(url.path)")

        let data: Data
        do {
            data = try fileReader.data(at: url)
        } catch {
            Log.error(#file, "  ❌ Failed to read local file data: \(error.localizedDescription)")
            return .failure(.manifestParseFailed)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            Log.error(#file, "  ❌ Failed to parse local file as JSON")
            return .failure(.manifestParseFailed)
        }

        Log.debug(#file, "  ✅ Successfully parsed local manifest JSON")

        guard let fulfillURL = book.bearerTokenFulfillURL else {
            return .success((json: json, decryptor: nil))
        }

        Log.debug(#file, "  🔑 Bearer token book - refreshing token before playback")
        if let newToken = await tokenRefresher.refreshToken(from: fulfillURL) {
            Log.info(#file, "  ✅ Bearer token refreshed before playback")
            book.bearerToken = newToken.accessToken
        } else {
            Log.warn(#file, "  ⚠️ Bearer token refresh failed - proceeding with existing token")
        }
        return .success((json: json, decryptor: nil))
    }
}
