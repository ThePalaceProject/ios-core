//
//  LCPAdapter.swift
//  Palace
//
//  LCP `AudiobookVendorAdapter`: source load plus license re-download.
//  `canHandle` delegates to `LCPAudiobooks.hasLCPAcquisition(_:)`, the recursive
//  predicate that handles the Marketplace OPDS shape (PP-4407). The file is
//  `#if LCP`-gated so Palace-noDRM excludes it.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

#if LCP

import Foundation
import PalaceLogging
@preconcurrency import PalaceAudiobookToolkit
import PalaceBookModel
import PalaceUtilities

/// Narrow seams for the two collaborators LCPAdapter needs. Defined here so
/// the adapter is unit-testable without retrofitting protocols onto the @objc
/// `MyBooksDownloadCenter` / `TPPNetworkExecutor` types. Concrete conformances
/// live at the bottom of this file; tests substitute in-memory spies.
protocol LCPAdapterDownloadCenter: AnyObject {
    func fileUrl(for identifier: String) -> URL?
}

/// `@MainActor` and `async` for the reason recorded on
/// `AudiobookVendorAdapter` (PP-5301): the license re-download used to deliver
/// on URLSession's queue into a main-actor adapter.
@MainActor
protocol LCPAdapterNetworkExecutor: AnyObject {
    /// The license body and its `URLResponse`. Throws the transport error
    /// rather than returning it beside the data.
    func fetchLicense(from reqURL: URL) async throws -> (Data, URLResponse?)
}

extension MyBooksDownloadCenter: LCPAdapterDownloadCenter {}

extension TPPNetworkExecutor: LCPAdapterNetworkExecutor {
    func fetchLicense(from reqURL: URL) async throws -> (Data, URLResponse?) {
        // `request(for:)` for the reason recorded on
        // `ProductionAudiobookManifestFetcher.fetchData`: the request-taking
        // overload dispatches what it is handed, so a bare `URLRequest(url:)`
        // reaches the CM with no bearer token. That comment also records what
        // it actually costs, which is a 401 round trip and a spurious refresh
        // rather than a terminal failure on the default auth types.
        try await GET(request: request(for: reqURL),
                      cachePolicy: .useProtocolCachePolicy,
                      useTokenIfAvailable: true)
    }
}

final class LCPAdapter: AudiobookVendorAdapter {

    private let downloadCenter: LCPAdapterDownloadCenter
    private let networkExecutor: LCPAdapterNetworkExecutor
    private let fileManager: FileManager
    private let lcpAudiobooksFactory: (URL) -> LCPAudiobooks?

    init(
        downloadCenter: LCPAdapterDownloadCenter,
        networkExecutor: LCPAdapterNetworkExecutor,
        fileManager: FileManager = .default,
        lcpAudiobooksFactory: @escaping (URL) -> LCPAudiobooks? = { LCPAudiobooks(for: $0) }
    ) {
        self.downloadCenter = downloadCenter
        self.networkExecutor = networkExecutor
        self.fileManager = fileManager
        self.lcpAudiobooksFactory = lcpAudiobooksFactory
    }

    func canHandle(_ book: TPPBook) -> Bool {
        LCPAudiobooks.hasLCPAcquisition(book)
    }

    func resolveManifest(
        for book: TPPBook
    ) async -> Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError> {
        switch await prepareLCPSource(for: book) {
        case .success(let sourceURL):
            return await loadLCPContent(book: book, lcpSourceURL: sourceURL)
        case .failure(let err):
            return .failure(err)
        }
    }

    // MARK: - LCP source preparation
    //
    // Three-tier source resolution: local .lcpa, else cached .lcpl sibling,
    // else re-download .lcpl from the book's fulfill URL.

    private func prepareLCPSource(for book: TPPBook) async -> Result<URL, AudiobookLoadError> {
        if let localURL = downloadCenter.fileUrl(for: book.identifier),
           fileManager.fileExists(atPath: localURL.path) {
            return .success(localURL)
        }
        if let license = licenseURL(forBookIdentifier: book.identifier) {
            return .success(license)
        }
        Log.info(#file, "LCP audiobook with no local files - re-downloading license")
        return await redownloadLCPLicense(for: book)
    }

    private func loadLCPContent(
        book: TPPBook,
        lcpSourceURL: URL
    ) async -> Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError> {
        guard let lcpAudiobooks = lcpAudiobooksFactory(lcpSourceURL) else {
            Log.error(#file, "Failed to create LCPAudiobooks instance for \(lcpSourceURL.path)")
            return .failure(.lcpInstantiationFailed)
        }
        if let cached = lcpAudiobooks.cachedContentDictionary() as? [String: Any] {
            return .success((json: cached, decryptor: lcpAudiobooks))
        }

        // `contentDictionary` is an `@objc` completion-handler API whose
        // `NSDictionary` payload is not `Sendable`, so the continuation carries
        // it in `ManifestJSONBox`. This is the only crossing left on the path;
        // the resumption lands back on this adapter's actor.
        let outcome: Result<ManifestJSONBox, AudiobookLoadError> = await withCheckedContinuation { continuation in
            lcpAudiobooks.contentDictionary { dict, error in
                if let error = error {
                    Log.error(#file, "LCP content dictionary error: \(error.localizedDescription)")
                    continuation.resume(returning: .failure(.lcpDecryptionFailed(underlying: error)))
                    return
                }
                guard let json = dict as? [String: Any] else {
                    continuation.resume(returning: .failure(.lcpDecryptionFailed(underlying: nil)))
                    return
                }
                continuation.resume(returning: .success(ManifestJSONBox(json)))
            }
        }

        switch outcome {
        case .success(let box):
            return .success((json: box.value, decryptor: lcpAudiobooks))
        case .failure(let err):
            return .failure(err)
        }
    }

    private func redownloadLCPLicense(for book: TPPBook) async -> Result<URL, AudiobookLoadError> {
        guard let fulfillURL = book.defaultAcquisition?.hrefURL else {
            return .failure(.missingFulfillURL)
        }
        guard let contentURL = downloadCenter.fileUrl(for: book.identifier) else {
            return .failure(.missingContentDirectory)
        }
        let licenseFileURL = contentURL.deletingPathExtension().appendingPathExtension("lcpl")
        Log.info(#file, "Fetching LCP license from: \(fulfillURL.host ?? "unknown")")

        let data: Data
        let response: URLResponse?
        do {
            (data, response) = try await networkExecutor.fetchLicense(from: fulfillURL)
        } catch {
            return .failure(.licenseDownloadFailed(underlying: error))
        }

        guard !data.isEmpty else {
            return .failure(.licenseDownloadFailed(underlying: nil))
        }
        if let httpResponse = response as? HTTPURLResponse, !httpResponse.isSuccess() {
            return .failure(.licenseDownloadFailed(underlying: nil))
        }
        do {
            let directory = licenseFileURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try data.write(to: licenseFileURL, options: .atomic)
        } catch {
            return .failure(.licenseSaveFailed(underlying: error))
        }
        return .success(licenseFileURL)
    }

    private func licenseURL(forBookIdentifier identifier: String) -> URL? {
        guard let contentURL = downloadCenter.fileUrl(for: identifier) else { return nil }
        let license = contentURL.deletingPathExtension().appendingPathExtension("lcpl")
        return fileManager.fileExists(atPath: license.path) ? license : nil
    }
}

#endif
