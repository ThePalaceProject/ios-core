//
//  BookFileManager.swift
//  Palace
//
//  Owns the on-disk path geometry for downloaded books — the per-account
//  content directory, the hashed file name + extension scheme that
//  fileUrl(for:) uses, and the LCP-aware extension selection. Extracted from
//  MyBooksDownloadCenter so the path/url logic can be unit-tested with a
//  temp-dir FileManager and a registry mock, without standing up a full
//  download center. MyBooksDownloadCenter still exposes the same public
//  fileUrl(for:) API surface — those methods now delegate here, so the 15+
//  external callers (BookDetailViewModel, BookCellModel, AudiobookLoader,
//  BookRegistrySync, etc.) keep working unchanged.
//

import Foundation
import PalaceBookModel
import PalaceBookRegistry

/// Resolves the on-disk URL for a book download. Per-account, hashed
/// identifier, LCP-aware file extension. Creates the content directory on
/// demand. No network, no DRM logic — just paths.
/// Non-final to allow test-only subclassing in `SpyBookFileManager`
/// (LocalBookContentServiceTests). The dynamic-dispatch cost is
/// negligible — `fileUrl(for:)` is not on a hot path.
class BookFileManager {

    private let bookRegistry: TPPBookRegistryProvider
    /// Account-scope read seam (god-class decomposition Wave 3, S2). Was the
    /// concrete `AccountsManager`; now the Downloads-owned
    /// `DownloadAccountScopeProviding` so this type carries no Accounts
    /// dependency into PalaceDownloads at 3b. Only `currentAccountID` is read.
    private let accountScope: any DownloadAccountScopeProviding
    private let fileManager: FileManager
    /// Test-only override for the per-account content directory lookup.
    /// Production passes nil so `contentDirectoryURL(_:)` resolves the
    /// directory under iOS's Application Support, as it always has.
    /// Tests (e.g. `ColdStartResumeIntegrationTests`) inject a closure
    /// returning a temp dir so on-disk fixtures can be staged without
    /// depending on a real per-account App Support directory. Semantics
    /// match the existing production return: nil means "no directory".
    private let directoryProvider: ((String?) -> URL?)?
    /// Identifiers of side-loaded books, resolved on each read. Side-loaded
    /// content is account-agnostic and is written under one fixed account
    /// (`SideloadedBookRegistry.sideloadContentAccountID`); this provider lets
    /// `fileUrl(for:account:)` pin a side-loaded id to that account so a
    /// library switch cannot orphan its file. Production resolves it lazily
    /// through `AppContainer` (same cycle-avoidance pattern as elsewhere);
    /// tests inject a fixed set. See sideloading-plan.md R6.
    private let sideloadedIdentifiersProvider: () -> Set<String>

    init(
        bookRegistry: TPPBookRegistryProvider = AppContainer.production().bookRegistry,
        accountScope: any DownloadAccountScopeProviding = AppContainer.production().downloadAccountContext,
        fileManager: FileManager = .default,
        directoryProvider: ((String?) -> URL?)? = nil,
        sideloadedIdentifiersProvider: @escaping () -> Set<String> = { AppContainer.production().sideloadedBookRegistry.identifiers }
    ) {
        self.bookRegistry = bookRegistry
        self.accountScope = accountScope
        self.fileManager = fileManager
        self.directoryProvider = directoryProvider
        self.sideloadedIdentifiersProvider = sideloadedIdentifiersProvider
    }

    // MARK: - File URL

    /// Convenience: looks the book up in the registry and resolves its URL
    /// under the current account. Returns nil if the book is unknown or the
    /// content directory can't be created.
    func fileUrl(for identifier: String) -> URL? {
        fileUrl(for: identifier, account: accountScope.currentAccountID)
    }

    func fileUrl(for identifier: String, account: String?) -> URL? {
        guard let book = bookRegistry.book(forIdentifier: identifier) else {
            return nil
        }
        // Component 4 (sideloading-plan.md R6): side-loaded books are
        // account-agnostic — their file is written under one fixed account.
        // If `currentAccount` (or the caller-supplied account) differs, the
        // per-account path would resolve the wrong directory → nil → the
        // reader can't open the book after a library switch. Pin the read to
        // the same fixed account the import wrote to. This is the single read
        // choke point every `fileUrl(for: identifier)` overload funnels
        // through, so the reader path is fixed without touching
        // MyBooksDownloadCenter.
        //
        // Perf: this method resolves EVERY book-file URL app-wide, so gate the
        // provider call (NSLock + Set copy) behind the cheap "sideload-" prefix
        // check. Side-loaded ids are minted with that prefix
        // (`SideloadedBookManager.contentIdentifier`), so a normal id skips the
        // lock entirely. The provider membership check is retained for
        // prefixed ids as defense in depth (an id could carry the prefix
        // without being registered). Coupling: this prefix MUST match the one
        // `SideloadedBookManager.contentIdentifier` mints.
        let resolvedAccount = (identifier.hasPrefix("sideload-")
            && sideloadedIdentifiersProvider().contains(identifier))
            ? SideloadedBookRegistry.sideloadContentAccountID
            : account
        return fileUrl(for: book, account: resolvedAccount)
    }

    /// Returns the file URL for a book, accepting the book directly instead
    /// of looking it up in the registry. Useful during registry loading
    /// when the registry hasn't been populated yet.
    func fileUrl(for book: TPPBook, account: String?) -> URL? {
        let ext = pathExtension(for: book)
        guard let directoryURL = contentDirectoryURL(account) else { return nil }
        let hashedIdentifier = book.identifier.sha256()
        return directoryURL.appendingPathComponent(hashedIdentifier).appendingPathExtension(ext)
    }

    // MARK: - Content Directory

    /// Resolves the content directory under the given account, creating it
    /// on disk if it doesn't already exist. Returns nil if the helper can't
    /// resolve the per-account directory (which means the account string was
    /// invalid) or if directory creation fails.
    func contentDirectoryURL(_ account: String?) -> URL? {
        // Test seam: when an override is installed, it owns the directory
        // contract end-to-end (no App Support resolution, no on-disk
        // create). Production code path is the `else` branch below.
        if let directoryProvider {
            return directoryProvider(account)
        }
        guard let directoryURL = TPPBookContentMetadataFilesHelper.directory(for: account ?? "")?.appendingPathComponent("content") else {
            NSLog("[contentDirectoryURL] nil directory.")
            return nil
        }

        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            } catch {
                NSLog("Failed to create directory.")
                return nil
            }
        }
        directoryURL.excludeFromBackup()

        return directoryURL
    }

    // MARK: - Path Extension

    /// File extension for the book's on-disk artefact. LCP audiobooks land
    /// as `.lcpa`, LCP PDFs as `.zip`, everything else as `.epub`. The LCP
    /// branches are compiled out of Palace-noDRM via `#if LCP`.
    ///
    /// LCP detection uses `hasLCPAcquisition` (recursive scan of the full
    /// acquisition chain including indirect entries) rather than
    /// `canOpenBook` (which inspects only `defaultAcquisition.type`).
    /// Marketplace OPDS feeds wrap the LCP license in
    /// `opds-publication+json → [LCP license → audiobook+lcp | application/pdf]`
    /// with the LCP MIME *nested* in the indirect chain — `canOpenBook`
    /// misses this and the file gets saved as `.epub`, breaking the LCP
    /// extract pass. PP-4407 closed this for audiobooks; PP-4454 mirrors
    /// the fix to PDFs.
    func pathExtension(for book: TPPBook?) -> String {
        #if LCP
        if let book = book {
            if LCPAudiobooks.hasLCPAcquisition(book) {
                return "lcpa"
            }
            if LCPPDFs.hasLCPAcquisition(book) {
                return "zip"
            }
        }
        #endif
        return "epub"
    }
}
