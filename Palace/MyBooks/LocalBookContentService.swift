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
import PalaceBookModel
import PalaceBookRegistry

/// File-system lifecycle for downloaded book content.
/// Non-final to allow test-only subclassing in `SpyLocalContentService`.
/// The dynamic-dispatch cost is negligible — none of these methods are
/// called in tight loops.
class LocalBookContentService {

    private let bookRegistry: TPPBookRegistryProvider
    private let accountsManager: AccountsManager
    private let bookFileManager: BookFileManager
    private let fileManager: FileManager

    init(
        bookRegistry: TPPBookRegistryProvider = AppContainer.production().bookRegistry,
        accountsManager: AccountsManager = AppContainer.production().accountsManager,
        bookFileManager: BookFileManager? = nil,
        fileManager: FileManager = .default
    ) {
        self.bookRegistry = bookRegistry
        self.accountsManager = accountsManager
        self.bookFileManager = bookFileManager ?? BookFileManager(
            bookRegistry: bookRegistry,
            accountScope: AccountsManagerDownloadContextAdapter(accountsManager: accountsManager),
            fileManager: fileManager
        )
        self.fileManager = fileManager
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

    /// Silently re-downloads the .lcpa content file for an LCP audiobook
    /// that only has the .lcpl license. The book stays in
    /// `.downloadSuccessful` (playable via streaming) while the download
    /// runs in the background (PP-3704).
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

        Log.info(#file, "📥 [LCP RE-DOWNLOAD] Starting background .lcpa download for '\(book.title)'")

        let lcpService = LCPLibraryService()
        _ = lcpService.fulfill(licenseURL, progress: { _ in }) { [fileManager] localUrl, error in
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
                Log.warn(#file, "📥 [LCP RE-DOWNLOAD] ⚠️ File move failed for '\(book.title)': \(error.localizedDescription) — streaming still available")
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
