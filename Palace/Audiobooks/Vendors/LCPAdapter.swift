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
@preconcurrency import ReadiumShared
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
        // they open on that loan's returned or expired status (PP-5440). One
        // issued before the current loan began is checked against the loan's
        // own licence; nothing is removed unless that check shows another ID.
        let loanStart = LCPLoanLicense.loanStart(of: book)
        if let license = licenseURL(forBookIdentifier: book.identifier),
           let loanStart,
           LCPLoanLicense.needsCheck(licenseAt: license, loanStart: loanStart) {
            await checkLicense(at: license, for: book, loanStart: loanStart)
        }
        let license = licenseURL(forBookIdentifier: book.identifier)
        if let localURL = downloadCenter.fileUrl(for: book.identifier),
           fileManager.fileExists(atPath: localURL.path),
           Self.archiveIsComplete(at: localURL) {
            // A package opens on the licence embedded in it, not on the `.lcpl`.
            if let embedded = await LCPLoanLicense.license(inPackageAt: localURL),
               LCPLoanLicense.predatesLoan(embedded, loanStart: loanStart) {
                if let license, let currentId = TPPLCPLicense(url: license)?.identifier {
                    if embedded.identifier != currentId {
                        Log.warn(#file, "LCP audiobook \(book.identifier): the local archive holds an earlier loan's licence; removing it")
                        removePackage(at: localURL, embeddedLicense: embedded)
                        return .success(license)
                    }
                } else if license == nil {
                    return await replaceLicenseOfPackage(at: localURL, embedded: embedded, for: book, loanStart: loanStart)
                }
            }
            Log.info(#file, "LCP audiobook \(book.identifier): opening the local archive")
            return .success(localURL)
        }
        if let license {
            Log.info(#file, "LCP audiobook \(book.identifier): streaming from the license")
            return .success(license)
        }
        Log.info(#file, "LCP audiobook with no local files - re-downloading license")
        return await redownloadLCPLicense(for: book)
    }

    /// Fetches the loan's licence and compares it with the one on disk. The
    /// same ID confirms the licence; another ID replaces it and removes the
    /// ranges kept for the old one. A failed fetch changes nothing.
    private func checkLicense(at license: URL, for book: TPPBook, loanStart: Date) async {
        guard case .success(let data) = await fetchLoanLicense(for: book),
              let fetched = try? JSONDecoder().decodeGuarded(TPPLCPLicense.self, from: data)
        else {
            Log.warn(#file, "LCP audiobook \(book.identifier): could not fetch the loan's licence; keeping the files on disk")
            return
        }
        if fetched.identifier == TPPLCPLicense(url: license)?.identifier {
            LCPLoanLicense.markVerified(licenseAt: license, loanStart: loanStart)
            return
        }
        Log.warn(#file, "LCP audiobook \(book.identifier): the licence on disk is from an earlier loan; replacing it")
        // Keyed by the old licence, so it is removed before the file is replaced.
        // A package holding the old licence is removed by the caller's package check.
        LCPAudiobooks.removeArchiveStore(forLicenseAt: license)
        do {
            try data.write(to: license, options: .atomic)
        } catch {
            Log.error(#file, "LCP audiobook \(book.identifier): could not store the loan's licence: \(error.localizedDescription)")
        }
    }

    /// No `.lcpl` beside a package whose licence predates the loan: fetch the
    /// loan's licence, keep the package only if it holds that same licence.
    private func replaceLicenseOfPackage(
        at packageURL: URL,
        embedded: TPPLCPLicense,
        for book: TPPBook,
        loanStart: Date?
    ) async -> Result<URL, AudiobookLoadError> {
        guard case .success(let license) = await redownloadLCPLicense(for: book) else {
            return .success(packageURL)
        }
        if TPPLCPLicense(url: license)?.identifier == embedded.identifier {
            if let loanStart {
                LCPLoanLicense.markVerified(licenseAt: license, loanStart: loanStart)
            }
            return .success(packageURL)
        }
        removePackage(at: packageURL, embeddedLicense: embedded)
        return .success(license)
    }

    private func removePackage(at packageURL: URL, embeddedLicense: TPPLCPLicense) {
        if let href = embeddedLicense.firstLink(withRel: .publication)?.href,
           let publication = HTTPURL(string: href) {
            LCPAudiobooks.removeArchiveStore(forPublicationAt: publication)
        }
        try? fileManager.removeItem(at: packageURL)
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
        guard book.defaultAcquisition?.hrefURL != nil else {
            return .failure(.missingFulfillURL)
        }
        guard let contentURL = downloadCenter.fileUrl(for: book.identifier) else {
            return .failure(.missingContentDirectory)
        }
        let licenseFileURL = contentURL.deletingPathExtension().appendingPathExtension("lcpl")
        let data: Data
        switch await fetchLoanLicense(for: book) {
        case .success(let fetched):
            data = fetched
        case .failure(let error):
            return .failure(error)
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

    /// The loan's licence from its fulfil link, without writing it.
    private func fetchLoanLicense(for book: TPPBook) async -> Result<Data, AudiobookLoadError> {
        guard let fulfillURL = book.defaultAcquisition?.hrefURL else {
            return .failure(.missingFulfillURL)
        }
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
        return .success(data)
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

    /// Extended attribute on a `.lcpl` recording the loan start it was checked
    /// against. An attribute rather than a file: it goes when the licence file
    /// is replaced or deleted, so it cannot outlive the licence it describes.
    static let verifiedLoanStartAttribute = "org.thepalaceproject.lcp.verified-loan-start"

    /// Records that the licence at `licenseURL` was confirmed against the
    /// loan that started at `loanStart`, so later opens do not fetch again.
    static func markVerified(licenseAt licenseURL: URL, loanStart: Date) {
        let value = Data(verifiedValue(for: loanStart).utf8)
        let result = value.withUnsafeBytes { bytes in
            setxattr(licenseURL.path, verifiedLoanStartAttribute, bytes.baseAddress, bytes.count, 0, 0)
        }
        if result != 0 {
            Log.warn(#file, "Could not record the licence check for \(licenseURL.lastPathComponent): errno \(errno)")
        }
    }

    static func isVerified(licenseAt licenseURL: URL, loanStart: Date) -> Bool {
        let size = getxattr(licenseURL.path, verifiedLoanStartAttribute, nil, 0, 0, 0)
        guard size > 0 else { return false }
        // A short read leaves zeros in the buffer, which then fails the compare.
        var buffer = [UInt8](repeating: 0, count: size)
        _ = getxattr(licenseURL.path, verifiedLoanStartAttribute, &buffer, size, 0, 0)
        return String(decoding: buffer, as: UTF8.self) == verifiedValue(for: loanStart)
    }

    /// True when the `.lcpl` at `licenseURL` predates the loan and has not
    /// been confirmed against it. Such a licence may be an earlier loan's.
    static func needsCheck(licenseAt licenseURL: URL, loanStart: Date?) -> Bool {
        guard let loanStart, predatesLoan(TPPLCPLicense(url: licenseURL), loanStart: loanStart) else {
            return false
        }
        return !isVerified(licenseAt: licenseURL, loanStart: loanStart)
    }

    private static func verifiedValue(for loanStart: Date) -> String {
        String(format: "%.0f", loanStart.timeIntervalSince1970)
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
