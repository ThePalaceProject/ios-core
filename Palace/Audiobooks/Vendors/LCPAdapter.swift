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
import PalaceNetwork
import PalaceCatalog
import ReadiumZIPFoundation

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
        // Licences on disk can belong to a loan that ended without an in-app
        // Return: nothing replaces them when the title is borrowed again, and
        // they open on that loan's returned or expired status (PP-5440). A
        // licence issued before the current loan began is from an earlier one.
        let loanStart = LCPLoanLicense.loanStart(of: book)
        let license = licenseURL(forBookIdentifier: book.identifier)
        if let license, LCPLoanLicense.predatesLoan(TPPLCPLicense(url: license), loanStart: loanStart) {
            Log.warn(#file, "LCP audiobook \(book.identifier): the licence on disk is from an earlier loan; fetching the current one")
            discardEarlierLoanFiles(for: book, licenseAt: license)
            return await redownloadLCPLicense(for: book)
        }
        if let localURL = downloadCenter.fileUrl(for: book.identifier),
           fileManager.fileExists(atPath: localURL.path),
           Self.archiveIsComplete(at: localURL) {
            // A package opens on the licence embedded in it, not on the `.lcpl`.
            let embedded = await LCPLoanLicense.license(inPackageAt: localURL)
            if LCPLoanLicense.predatesLoan(embedded, loanStart: loanStart) {
                Log.warn(#file, "LCP audiobook \(book.identifier): the local archive holds an earlier loan's licence; not opening it")
            } else {
                Log.info(#file, "LCP audiobook \(book.identifier): opening the local archive")
                return .success(localURL)
            }
        }
        if let license {
            Log.info(#file, "LCP audiobook \(book.identifier): streaming from the license")
            return .success(license)
        }
        Log.info(#file, "LCP audiobook with no local files - re-downloading license")
        return await redownloadLCPLicense(for: book)
    }

    /// Removes the earlier loan's package and its retained byte ranges. The
    /// `.lcpl` is left for `redownloadLCPLicense` to overwrite, so a failed
    /// fetch leaves it for the next open to try again.
    private func discardEarlierLoanFiles(for book: TPPBook, licenseAt license: URL) {
        LCPAudiobooks.removeArchiveStore(forLicenseAt: license)
        if let contentURL = downloadCenter.fileUrl(for: book.identifier),
           fileManager.fileExists(atPath: contentURL.path) {
            try? fileManager.removeItem(at: contentURL)
        }
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
            Log.error(#file, "LCP license download for \(book.identifier) failed: \(error.localizedDescription)")
            return .failure(.licenseDownloadFailed(underlying: error))
        }

        guard !data.isEmpty else {
            Log.error(#file, "LCP license download for \(book.identifier) returned an empty body")
            return .failure(.licenseDownloadFailed(underlying: nil))
        }
        if let httpResponse = response as? HTTPURLResponse, !httpResponse.isSuccess() {
            Log.error(#file, "LCP license download for \(book.identifier) returned HTTP \(httpResponse.statusCode)")
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

    /// Whether a local `.lcpa` holds a whole archive, as opposed to a download
    /// still in progress.
    ///
    /// Existence is not enough. A partial download exists from its first byte,
    /// and reading the book from it reads the archive off disk, where the file
    /// fills from the start: a chapter near the beginning plays at once while a
    /// chapter further in cannot be read until the download reaches it. A
    /// patron sees a resumed chapter stall, with no error, until the transfer
    /// passes that offset. Streaming the licence from the origin has no such
    /// gap, so an incomplete file must fall through to it.
    ///
    /// A ZIP ends with an end-of-central-directory record, written last, so its
    /// signature is absent from every partial file and present in every whole
    /// one. The record sits within the last 64 KB even with a maximal comment,
    /// so this reads the tail rather than the file.
    static func archiveIsComplete(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= UInt64(minimumEOCDLength) else {
            return false
        }
        let tailLength = min(size, UInt64(maximumEOCDTailLength))
        guard (try? handle.seek(toOffset: size - tailLength)) != nil,
              let tail = try? handle.read(upToCount: Int(tailLength))
        else {
            return false
        }
        return tail.range(of: eocdSignature) != nil
    }

    /// `PK\u{05}\u{06}`, the end-of-central-directory signature.
    private static let eocdSignature = Data([0x50, 0x4B, 0x05, 0x06])

    /// The record's fixed fields, with an empty comment. A file shorter than
    /// this cannot hold one, so matching the signature alone would accept four
    /// bytes of a download that had barely started.
    private static let minimumEOCDLength = 22

    /// The record is 22 bytes plus a comment of at most 65535, and ZIP64 adds
    /// its own locator, so the last 64 KiB plus a margin always contains it.
    private static let maximumEOCDTailLength = 66 * 1024

    private func licenseURL(forBookIdentifier identifier: String) -> URL? {
        guard let contentURL = downloadCenter.fileUrl(for: identifier) else { return nil }
        let license = contentURL.deletingPathExtension().appendingPathExtension("lcpl")
        return fileManager.fileExists(atPath: license.path) ? license : nil
    }
}

/// Whether a licence on disk belongs to the book's current loan (PP-5440).
enum LCPLoanLicense {

    /// Allowance for the CM's loan start and the licence server's issue time
    /// being stamped by different clocks.
    static let issueSkew: TimeInterval = 60

    /// Where fulfilment injects the licence (`TPPLicensesService.pathInZip`):
    /// `license.lcpl` for audiobooks, `META-INF/license.lcpl` for EPUBs.
    static let entryPaths = ["license.lcpl", "META-INF/license.lcpl"]

    /// The current loan's start, from the loans feed. Nil for anything that is
    /// not a limited loan, or a feed without `since`.
    static func loanStart(of book: TPPBook) -> Date? {
        var since: Date?
        book.defaultAcquisition?.availability.match(
            unavailable: nil,
            limited: { since = $0.since },
            unlimited: nil,
            reserved: nil,
            ready: nil
        )
        return since
    }

    /// True only when both dates are known and the licence was issued before
    /// the loan began. Unknown keeps the licence, as before PP-5440.
    static func predatesLoan(_ license: TPPLCPLicense?, loanStart: Date?) -> Bool {
        guard let issued = license?.issued, let loanStart else { return false }
        return issued < loanStart.addingTimeInterval(-issueSkew)
    }

    /// The licence embedded in the package, read without the network; nil
    /// when it has none or cannot be read.
    static func license(inPackageAt packageURL: URL) async -> TPPLCPLicense? {
        guard let archive = try? await Archive(url: packageURL, accessMode: .read) else { return nil }
        for path in entryPaths {
            guard let entry = try? await archive.get(path) else { continue }
            let buffer = LicenseDataBuffer()
            guard (try? await archive.extract(entry, consumer: { buffer.append($0) })) != nil,
                  let license = try? JSONDecoder().decodeGuarded(TPPLCPLicense.self, from: buffer.data)
            else {
                continue
            }
            return license
        }
        return nil
    }
}

/// `Archive.extract` delivers chunks to a `@Sendable` closure, so the bytes
/// are collected under a lock.
private final class LicenseDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ chunk: Data) { lock.withLock { storage.append(chunk) } }
    var data: Data { lock.withLock { storage } }
}

#endif
