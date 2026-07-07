//
//  LCPAdapter.swift
//  Palace
//
//  LCP `AudiobookVendorAdapter` implementation. Wraps the LCP source-load +
//  license-redownload logic carved verbatim from pre-swarm AudiobookLoader.swift
//  (lines 149-164 + 222-341). Module C of swarm_5c8ddbd5. `canHandle` delegates
//  to `LCPAudiobooks.hasLCPAcquisition(_:)` — the recursive predicate that
//  catches the Marketplace OPDS-shape regression PP-4407 (kill point lives in
//  `LCPAcquisitionPredicateTests`). Constructor-style DI; entire file is
//  `#if LCP`-gated so Palace-noDRM excludes it.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

#if LCP

import Foundation
import PalaceLogging
@preconcurrency import PalaceAudiobookToolkit

/// Narrow seams for the two collaborators LCPAdapter needs. Defined here so
/// the adapter is unit-testable without retrofitting protocols onto the @objc
/// `MyBooksDownloadCenter` / `TPPNetworkExecutor` types. Concrete conformances
/// live at the bottom of this file; tests substitute in-memory spies.
protocol LCPAdapterDownloadCenter: AnyObject {
    func fileUrl(for identifier: String) -> URL?
}

protocol LCPAdapterNetworkExecutor: AnyObject {
    @discardableResult
    func GET(
        _ reqURL: URL,
        completion: @escaping (_ result: Data?, _ response: URLResponse?, _ error: Error?) -> Void
    ) -> URLSessionDataTask?
}

extension MyBooksDownloadCenter: LCPAdapterDownloadCenter {}

extension TPPNetworkExecutor: LCPAdapterNetworkExecutor {
    // Swift protocol conformance can't pick up the 4-arg @objc GET with
    // defaults, so we bridge with a 2-arg overload that fills the defaults.
    func GET(
        _ reqURL: URL,
        completion: @escaping (_ result: Data?, _ response: URLResponse?, _ error: Error?) -> Void
    ) -> URLSessionDataTask? {
        return GET(reqURL, cachePolicy: .useProtocolCachePolicy, useTokenIfAvailable: true, completion: completion)
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
        for book: TPPBook,
        completion: @escaping (Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError>) -> Void
    ) {
        // Box the non-`@Sendable` completion once. The LCP flow hands it across
        // the `prepareLCPSource` callback, `LCPAudiobooks.contentDictionary`
        // (whose completion IS `@Sendable`), and the `finishOnMain`
        // `DispatchQueue.main.async` hop — all `@Sendable` boundaries. Boxing
        // avoids marking the `AudiobookVendorAdapter` protocol `@Sendable`
        // (which would ripple to the loader + adapter test mocks). See
        // `AudiobookAdapterCompletionBox`.
        let completionBox = AudiobookAdapterCompletionBox(completion)
        prepareLCPSource(for: book) { [weak self] sourceResult in
            guard let self else { LCPAdapter.finishOnMain(completionBox, .failure(.cancelled)); return }
            switch sourceResult {
            case .success(let sourceURL):
                self.loadLCPContent(book: book, lcpSourceURL: sourceURL, completionBox: completionBox)
            case .failure(let err):
                LCPAdapter.finishOnMain(completionBox, .failure(err))
            }
        }
    }

    // MARK: - LCP source preparation
    //
    // Three-tier source resolution carved verbatim from pre-swarm
    // AudiobookLoader.swift (lines 222-241): local .lcpa, else cached .lcpl
    // sibling, else re-download .lcpl from the book's fulfill URL.

    private func prepareLCPSource(
        for book: TPPBook,
        completion: @escaping (Result<URL, AudiobookLoadError>) -> Void
    ) {
        if let localURL = downloadCenter.fileUrl(for: book.identifier),
           fileManager.fileExists(atPath: localURL.path) {
            completion(.success(localURL))
            return
        }
        if let license = licenseURL(forBookIdentifier: book.identifier) {
            completion(.success(license))
            return
        }
        Log.info(#file, "LCP audiobook with no local files - re-downloading license")
        redownloadLCPLicense(for: book, completion: completion)
    }

    private func loadLCPContent(
        book: TPPBook,
        lcpSourceURL: URL,
        completionBox: AudiobookAdapterCompletionBox
    ) {
        guard let lcpAudiobooks = lcpAudiobooksFactory(lcpSourceURL) else {
            Log.error(#file, "Failed to create LCPAudiobooks instance for \(lcpSourceURL.path)")
            LCPAdapter.finishOnMain(completionBox, .failure(.lcpInstantiationFailed))
            return
        }
        if let cached = lcpAudiobooks.cachedContentDictionary() as? [String: Any] {
            LCPAdapter.finishOnMain(completionBox, .success((json: cached, decryptor: lcpAudiobooks)))
            return
        }
        lcpAudiobooks.contentDictionary { dict, error in
            if let error = error {
                Log.error(#file, "LCP content dictionary error: \(error.localizedDescription)")
                LCPAdapter.finishOnMain(completionBox, .failure(.lcpDecryptionFailed(underlying: error)))
                return
            }
            guard let json = dict as? [String: Any] else {
                LCPAdapter.finishOnMain(completionBox, .failure(.lcpDecryptionFailed(underlying: nil)))
                return
            }
            LCPAdapter.finishOnMain(completionBox, .success((json: json, decryptor: lcpAudiobooks)))
        }
    }

    private func redownloadLCPLicense(
        for book: TPPBook,
        completion: @escaping (Result<URL, AudiobookLoadError>) -> Void
    ) {
        guard let fulfillURL = book.defaultAcquisition?.hrefURL else {
            completion(.failure(.missingFulfillURL))
            return
        }
        guard let contentURL = downloadCenter.fileUrl(for: book.identifier) else {
            completion(.failure(.missingContentDirectory))
            return
        }
        let licenseFileURL = contentURL.deletingPathExtension().appendingPathExtension("lcpl")
        Log.info(#file, "Fetching LCP license from: \(fulfillURL.host ?? "unknown")")

        _ = networkExecutor.GET(fulfillURL) { [fileManager] data, response, error in
            if let error = error {
                completion(.failure(.licenseDownloadFailed(underlying: error)))
                return
            }
            guard let data = data, !data.isEmpty else {
                completion(.failure(.licenseDownloadFailed(underlying: nil)))
                return
            }
            if let httpResponse = response as? HTTPURLResponse, !httpResponse.isSuccess() {
                completion(.failure(.licenseDownloadFailed(underlying: nil)))
                return
            }
            do {
                let directory = licenseFileURL.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: directory.path) {
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                }
                try data.write(to: licenseFileURL, options: .atomic)
            } catch {
                completion(.failure(.licenseSaveFailed(underlying: error)))
                return
            }
            completion(.success(licenseFileURL))
        }
    }

    private func licenseURL(forBookIdentifier identifier: String) -> URL? {
        guard let contentURL = downloadCenter.fileUrl(for: identifier) else { return nil }
        let license = contentURL.deletingPathExtension().appendingPathExtension("lcpl")
        return fileManager.fileExists(atPath: license.path) ? license : nil
    }

    /// Force completion onto the main thread — `AudiobookVendorAdapter`
    /// contract requires completion fires on main exactly once. Takes the
    /// `Sendable` completion box so the (possibly off-main) callers can hop to
    /// main via `DispatchQueue.main.async` without capturing the raw
    /// non-`@Sendable` completion across that boundary.
    private static func finishOnMain(
        _ completionBox: AudiobookAdapterCompletionBox,
        _ result: AudiobookAdapterCompletionBox.Outcome
    ) {
        if Thread.isMainThread { completionBox.fire(result) }
        else {
            // The `Outcome` payload carries `[String: Any]` (manifest) and a
            // `DRMDecryptor?` (toolkit protocol), neither Sendable-audited, so
            // capturing `result` directly into the `main.async` `@Sendable`
            // closure trips `sending 'result' risks data races`. Box it for the
            // single main hop — the outcome is produced once and consumed once.
            let outcomeBox = LCPOutcomeBox(result)
            DispatchQueue.main.async { completionBox.fire(outcomeBox.value) }
        }
    }
}

/// `Sendable` carrier for an `AudiobookAdapterCompletionBox.Outcome` crossing
/// the `finishOnMain` `DispatchQueue.main.async` hop.
///
/// The outcome's success payload holds a non-Sendable `[String: Any]` manifest
/// and an un-audited `DRMDecryptor?`; boxing lets it cross the main hop without
/// a `sending` diagnostic while keeping the `AudiobookVendorAdapter` completion
/// (and its loader/test call sites) free of a `@Sendable` requirement.
///
/// - Sendable invariant: `value` is set once at init and only read on the main
///   thread thereafter — the outcome is not mutated after boxing, so there is
///   no shared mutation. The `@unchecked` waiver covers only the un-audited
///   payload types. Mirrors `ManifestJSONBox` (AudiobookVendorAdapter).
private struct LCPOutcomeBox: @unchecked Sendable {
    let value: AudiobookAdapterCompletionBox.Outcome
    init(_ value: AudiobookAdapterCompletionBox.Outcome) {
        self.value = value
    }
}

#endif
