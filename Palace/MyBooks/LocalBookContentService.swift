//
//  LocalBookContentService.swift
//  Palace
//
//  Owns the on-disk lifecycle for downloaded book content — local-content
//  deletion (epub/pdf/audiobook with LCP variants) and the LCP audiobook
//  re-download flow that re-fetches the `.lcpa` content when only the
//  `.lcpl` license is left on disk (PP-3704).
//
//  Extracted from MyBooksDownloadCenter so the file-system-level lifecycle
//  can be exercised in isolation without standing up a download center.
//  MBDC keeps the same `deleteLocalContent(for:account:)` /
//  `deleteLocalContent(forBook:account:)` / `redownloadLCPContentFile(for:)`
//  public surface as 1-line delegators — preserves the 5+ external callers
//  (ReaderService, BookRegistrySync, TPPBookRegistryAsync, MyBooksViewModel,
//  MyBooksDownloadCenterProtocol).
//

import Foundation
import PalaceAudiobookToolkit
import PalaceLogging

/// File-system lifecycle for downloaded book content.
/// Non-final to allow test-only subclassing in `SpyLocalContentService`.
/// The dynamic-dispatch cost is negligible — none of these methods are
/// called in tight loops.
class LocalBookContentService {

    /// Shape of the LCP content-fulfillment call used by
    /// `redownloadLCPContentFile`. Injected so the in-flight guard and the
    /// progress plumbing can be exercised without a live `LCPLibraryService`, a
    /// license on disk, or a network fetch — the spy decides *when* completion
    /// fires, which is the only way to test that the in-flight slot is held for
    /// the duration and released afterwards.
    typealias LCPContentFulfilling = (
        _ licenseURL: URL,
        _ progress: @escaping (Double) -> Void,
        _ completion: @escaping (URL?, Error?) -> Void
    ) -> Void

    private let bookRegistry: TPPBookRegistryProvider
    private let accountsManager: AccountsManager
    private let bookFileManager: BookFileManager
    private let fileManager: FileManager
    private let lcpContentFulfiller: LCPContentFulfilling
    /// Per-instance so tests can drive the idle-expiry and heartbeat behaviour
    /// in milliseconds instead of waiting out the production window.
    private let inflightIdleTimeout: TimeInterval
    /// Whether the download CENTER is already transferring this book.
    ///
    /// The in-flight claim below only covers transfers this service starts. The
    /// fulfillment handler runs its own `.lcpa` transfer for a fresh borrow and
    /// registers it in `downloadInfo`, not here — two uncoordinated producers of
    /// the same file. Without consulting the download center, the open-time gate
    /// could find license-present/content-absent, claim a free slot, and start a
    /// duplicate alongside the handler's transfer.
    var downloadCenterHasTransfer: ((String) -> Bool)?

    /// Progress/activity sink for the LCP content re-download. Assigned by
    /// `MyBooksDownloadCenter` after `init` because the reporter is created
    /// later in that initializer than this service is (mirrors the existing
    /// `progressReporter.notificationSender = self` post-init wiring). `weak`
    /// because the reporter is owned by the download center.
    weak var contentDownloadReporter: DownloadProgressPublishing?

    /// Book identifiers whose `.lcpa` content download is currently running.
    ///
    /// The `fileExists` skip below cannot see an in-flight transfer, and two
    /// callers reach `redownloadLCPContentFile` independently: the registry-load
    /// self-heal (`BookRegistrySync`) and the open-time gate
    /// (`AudiobookSessionManager.gateOnLCPContentDownload`). Without this guard,
    /// tapping Listen during the self-heal's download window started a SECOND
    /// full transfer of the same archive; both completed, one was discarded, and
    /// the two competed for the patron's bandwidth. Verified on device against
    /// A1QA: 2 × 778 MB for one 778 MB audiobook.
    ///
    /// A claim is reclaimable rather than permanent, because a dropped callback
    /// is reachable: the fulfillment call runs on a background `URLSession` and a
    /// cancelled or suspended task can lose its completion, after which every
    /// later `redownloadLCPContentFile` would no-op and the open gate would
    /// dead-end at "Audiobook Unavailable" — the exact complaint the gate exists
    /// to remove.
    private struct ContentDownloadClaim {
        /// Identifies THIS transfer. Release and heartbeat both require it, so a
        /// late completion from an abandoned transfer cannot free, or keep
        /// alive, the slot belonging to a different one.
        let token: UUID
        /// Monotonic nanoseconds of the last sign of life. Monotonic rather than
        /// wall-clock so a clock adjustment or timezone change cannot make a
        /// live transfer look expired.
        var lastActivity: UInt64
    }

    private var inflightContentDownloads = [String: ContentDownloadClaim]()
    private let inflightLock = NSLock()

    /// How long a claim may go WITHOUT a sign of life before a later caller
    /// treats it as dead and reclaims the slot.
    ///
    /// This is an idle timeout, not a total-duration one, and the distinction is
    /// load-bearing. Sizing it to the open gate's 180s ceiling as a total
    /// duration would expire a healthy transfer of any of the titles this change
    /// was measured against (438 MB / 778 MB / 1,897 MB routinely exceed three
    /// minutes), so the patron's next Listen would start a SECOND full transfer
    /// — reintroducing the very defect the guard exists to prevent. The progress
    /// callback heartbeats the claim, so only a genuinely silent transfer ages
    /// out. Comfortably beyond the fulfillment session's own 60s request
    /// timeout, so a stalled connection fails there first.
    static let inflightContentDownloadIdleTimeout: TimeInterval = 180

    private static func monotonicNow() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    init(
        bookRegistry: TPPBookRegistryProvider = AppContainer.production().bookRegistry,
        accountsManager: AccountsManager = AppContainer.production().accountsManager,
        bookFileManager: BookFileManager? = nil,
        fileManager: FileManager = .default,
        lcpContentFulfiller: LCPContentFulfilling? = nil,
        inflightIdleTimeout: TimeInterval = LocalBookContentService.inflightContentDownloadIdleTimeout,
        downloadCenterHasTransfer: ((String) -> Bool)? = nil
    ) {
        self.inflightIdleTimeout = inflightIdleTimeout
        self.downloadCenterHasTransfer = downloadCenterHasTransfer
        self.bookRegistry = bookRegistry
        self.accountsManager = accountsManager
        self.bookFileManager = bookFileManager ?? BookFileManager(
            bookRegistry: bookRegistry,
            accountsManager: accountsManager,
            fileManager: fileManager
        )
        self.fileManager = fileManager
        self.lcpContentFulfiller = lcpContentFulfiller ?? { licenseURL, progress, completion in
            #if LCP
            _ = LCPLibraryService().fulfill(licenseURL, progress: progress, completion: completion)
            #else
            completion(nil, nil)
            #endif
        }
    }

    // MARK: - In-flight bookkeeping

    /// Claims the slot for `identifier`, returning the claim token, or `nil`
    /// when a transfer that is still showing signs of life already holds it —
    /// in which case the caller must not start another.
    private func claimContentDownloadSlot(
        _ identifier: String,
        now: UInt64 = LocalBookContentService.monotonicNow()
    ) -> UUID? {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        let idleLimit = UInt64(inflightIdleTimeout * 1_000_000_000)
        if let existing = inflightContentDownloads[identifier],
           now &- existing.lastActivity < idleLimit {
            return nil
        }
        // Either unclaimed, or the holder has been silent past the idle window
        // and its completion is never coming — reclaim rather than dedupe
        // against a dead transfer and leave the book unrecoverable.
        let token = UUID()
        inflightContentDownloads[identifier] = ContentDownloadClaim(token: token, lastActivity: now)
        return token
    }

    /// Records a sign of life for a claim. Called from the progress callback so
    /// a long but healthy transfer never ages out of its own slot.
    private func touchContentDownloadSlot(
        _ identifier: String,
        token: UUID,
        now: UInt64 = LocalBookContentService.monotonicNow()
    ) {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        guard inflightContentDownloads[identifier]?.token == token else { return }
        inflightContentDownloads[identifier]?.lastActivity = now
    }

    /// Releases the in-flight slot for `identifier`. Must run on every
    /// completion path — success, fulfillment error, and file-move failure —
    /// or the book can never be re-downloaded for the rest of the process.
    /// Token-matched so a late completion from a reclaimed transfer cannot free
    /// the slot its successor is holding.
    private func releaseContentDownloadSlot(_ identifier: String, token: UUID) {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        guard inflightContentDownloads[identifier]?.token == token else { return }
        inflightContentDownloads.removeValue(forKey: identifier)
    }

    /// Whether `token` is still the live claim for `identifier`. Reporter
    /// traffic is gated on this so an abandoned transfer's late progress sample
    /// or completion cannot drive — or prematurely close — the UI cue belonging
    /// to the transfer that reclaimed the slot.
    private func isCurrentClaim(_ identifier: String, token: UUID) -> Bool {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        return inflightContentDownloads[identifier]?.token == token
    }

    /// Test seam: whether a content download is currently claimed for
    /// `identifier`. Reads through the same lock as the mutators.
    func isContentDownloadInFlight(for identifier: String) -> Bool {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        return inflightContentDownloads[identifier] != nil
    }

    // MARK: - Delete local content

    /// Looks the book up in the registry and deletes its local content.
    /// Most callers use this overload; tests / cold-launch reconciliation
    /// can use the `forBook:` variant to avoid a second registry hit.
    func deleteLocalContent(for identifier: String, account: String? = nil) {
        guard let book = bookRegistry.book(forIdentifier: identifier) else {
            Log.warn(#file, "Could not find book to delete local content \(identifier)")
            return
        }
        deleteLocalContent(forBook: book, account: account)
    }

    /// Delete local content using a book reference directly, without reading the
    /// book registry. Use this from callers that already hold the book (or that
    /// are running inside a registry write barrier — looking up the identifier
    /// through `bookRegistry` there would re-enter the barrier and trip Swift's
    /// exclusivity check, e.g. BookRegistrySync.sync()'s reconciliation pass
    /// deleting expired/returned downloads.
    func deleteLocalContent(forBook book: TPPBook, account: String? = nil) {
        let currentAccount: String? = account ?? accountsManager.currentAccountId
        guard let bookURL = bookFileManager.fileUrl(for: book, account: currentAccount) else {
            Log.warn(#file, "Could not resolve fileUrl to delete local content \(book.identifier)")
            return
        }

        do {
            switch book.defaultBookContentType {
            case .epub, .pdf:
                if fileManager.fileExists(atPath: bookURL.path) {
                    try fileManager.removeItem(at: bookURL)
                } else {
                    Log.info(#file, "Content file already missing (nothing to delete): \(bookURL.lastPathComponent)")
                }
                // Historical cleanup of the LCPPDFs-extracted temp PDF is
                // obsolete post-migration to Readium PDFNavigator — pages
                // stream on demand and there is no temp extract to delete.
                #if LCP
                // Drop the on-disk TOC snapshot AND the decrypted PDF
                // extract so a re-borrow doesn't reuse stale cached
                // content against a potentially different loan.
                if book.defaultBookContentType == .pdf, let acct = currentAccount {
                    ReadiumPDFTOCCache.invalidate(bookIdentifier: book.identifier, account: acct)
                    LCPPDFDiskExtract.invalidate(bookIdentifier: book.identifier, account: acct)
                }
                #endif
            case .audiobook:
                try deleteLocalAudiobookContent(forAudiobook: book, at: bookURL)
            case .streamingHTML:
                // PP-4161: streaming-HTML has no local on-device asset to
                // delete. The reader streams from the server every open;
                // returning the title is the only side effect of "remove".
                break
            case .unsupported:
                Log.warn(#file, "Unsupported content type for deletion.")
            }
        } catch {
            Log.error(#file, "Failed to remove local content for book with identifier \(book.identifier): \(error.localizedDescription)")
        }
    }

    /// Audiobook variant of local-content deletion. LCP audiobooks are a
    /// single binary file — no manifest pass is needed and the toolkit's
    /// generic `deleteLocalContent` is skipped. Non-LCP audiobooks decode
    /// the manifest first so the toolkit can clean per-track files
    /// alongside the manifest itself.
    private func deleteLocalAudiobookContent(forAudiobook book: TPPBook, at bookURL: URL) throws {
        #if LCP
        let isLcpAudiobook = LCPAudiobooks.canOpenBook(book)
        #else
        let isLcpAudiobook = false
        #endif

        // LCP Audiobooks are a single binary file, without an easily loaded manifest.
        // So they skip this logic that deleted the local audio files, used by other
        // audiobook types.
        // TODO: Update LCP so we don't have to special case it here.
        if !isLcpAudiobook {
            let manifestData = try Data(contentsOf: bookURL)
            let manifest = try Manifest.customDecoder().decode(Manifest.self, from: manifestData)
            AudiobookFactory.audiobookClass(for: manifest).deleteLocalContent(manifest: manifest, bookIdentifier: book.identifier)
        }

        if fileManager.fileExists(atPath: bookURL.path) {
            try fileManager.removeItem(at: bookURL)
        } else {
            Log.info(#file, "Audiobook content already missing (nothing to delete): \(bookURL.lastPathComponent)")
        }
        Log.info(#file, "Successfully deleted audiobook manifest & content \(book.identifier)")
    }

    // MARK: - Re-download LCP content

    /// Re-downloads the `.lcpa` content file for an LCP audiobook that only has
    /// its `.lcpl` license on disk. Runs in the background; the book's registry
    /// state is left alone (see the `lcpContentDownloadPublisher` note in
    /// `DownloadProgressPublisher` for why this path does not move the book to
    /// `.downloading`). Originally PP-3704.
    ///
    /// Idempotent in two dimensions:
    ///  - content already on disk → skip (`fileExists`)
    ///  - a download already running for this book → skip (in-flight set)
    ///
    /// The second guard is the fix for the duplicate-transfer defect: the
    /// self-heal and the open-time gate both call this, and before the guard a
    /// Listen tap during the self-heal's window started a second full transfer
    /// of the same archive.
    ///
    /// Progress and an active/idle edge are reported to
    /// `contentDownloadReporter` so the half-sheet can show a real percentage
    /// for the whole wait instead of nothing.
    func redownloadLCPContentFile(for book: TPPBook) {
        #if LCP
        guard LCPAudiobooks.canOpenBook(book) else { return }
        guard let licenseURL = lcpLicenseURL(forBookIdentifier: book.identifier) else {
            Log.warn(#file, "📥 [LCP RE-DOWNLOAD] No license file found for '\(book.title)' — skipping")
            return
        }
        guard let destURL = bookFileManager.fileUrl(for: book.identifier) else { return }

        // Skip if .lcpa already exists (another re-download may have completed)
        if fileManager.fileExists(atPath: destURL.path) {
            Log.info(#file, "📥 [LCP RE-DOWNLOAD] .lcpa already exists for '\(book.title)' — skipping")
            return
        }

        let identifier = book.identifier

        // Skip if the download center is already transferring this book. Its
        // fulfillment-handler transfer is invisible to the claim map below, so
        // without this the two producers race and the patron pays for the
        // archive twice.
        if downloadCenterHasTransfer?(identifier) == true {
            Log.info(#file, "📥 [LCP RE-DOWNLOAD] the download center is already transferring '\(book.title)' — skipping duplicate")
            return
        }

        // Skip if a transfer for this book is already running. Claimed BEFORE
        // the fulfiller is invoked so a synchronous re-entrant call cannot slip
        // between the check and the start.
        guard let claimToken = claimContentDownloadSlot(identifier) else {
            Log.info(#file, "📥 [LCP RE-DOWNLOAD] a download is already in flight for '\(book.title)' — skipping duplicate")
            return
        }

        Log.info(#file, "📥 [LCP RE-DOWNLOAD] Starting background .lcpa download for '\(book.title)'")
        contentDownloadReporter?.sendLCPContentDownloadActive(bookIdentifier: identifier, active: true)

        let progressHandler: (Double) -> Void = { [weak self] fraction in
            // Heartbeat the claim: a multi-gigabyte transfer takes far longer
            // than the idle window, and without this it would age out of its own
            // slot mid-flight and the next Listen would start a duplicate.
            guard let self, self.isCurrentClaim(identifier, token: claimToken) else { return }
            self.touchContentDownloadSlot(identifier, token: claimToken)
            self.contentDownloadReporter?.sendProgress(bookIdentifier: identifier, progress: fraction)
        }

        lcpContentFulfiller(licenseURL, progressHandler) { [weak self, fileManager] localUrl, error in
            // Release the slot and close the UI cue on EVERY exit path below.
            defer {
                // Only the live claim may close the cue. A reclaimed transfer
                // reporting back late must not blank the bar of the transfer
                // that replaced it.
                let isLive = self?.isCurrentClaim(identifier, token: claimToken) ?? false
                self?.releaseContentDownloadSlot(identifier, token: claimToken)
                if isLive {
                    self?.contentDownloadReporter?.sendLCPContentDownloadActive(bookIdentifier: identifier, active: false)
                }
            }

            if let error {
                Log.error(#file, "📥 [LCP RE-DOWNLOAD] ❌ Failed for '\(book.title)': \(error.localizedDescription)")
                return
            }
            guard let localUrl else {
                Log.error(#file, "📥 [LCP RE-DOWNLOAD] ❌ No local URL returned for '\(book.title)'")
                return
            }

            do {
                let parentDir = destURL.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: parentDir.path) {
                    try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
                }
                parentDir.excludeFromBackup()
                try fileManager.moveItem(at: localUrl, to: destURL)
                Log.info(#file, "📥 [LCP RE-DOWNLOAD] ✅ .lcpa stored for '\(book.title)' — local playback now available")
            } catch {
                Log.warn(#file, "📥 [LCP RE-DOWNLOAD] ⚠️ File move failed for '\(book.title)': \(error.localizedDescription)")
            }
        }
        #endif
    }

    /// Returns the .lcpl license URL for an LCP audiobook, if it exists
    /// on disk. Used by the LCP re-download path; also exposed on
    /// `BookDetailViewModel.lcpLicenseURL(forBookIdentifier:downloadCenter:)`
    /// via a separate static helper.
    private func lcpLicenseURL(forBookIdentifier identifier: String) -> URL? {
        guard let bookURL = bookFileManager.fileUrl(for: identifier) else { return nil }
        let licenseURL = bookURL.deletingPathExtension().appendingPathExtension("lcpl")
        return fileManager.fileExists(atPath: licenseURL.path) ? licenseURL : nil
    }
}
