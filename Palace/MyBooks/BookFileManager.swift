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

/// Resolves the on-disk URL for a book download. Per-account, hashed
/// identifier, LCP-aware file extension. Creates the content directory on
/// demand. No network, no DRM logic — just paths.
/// Non-final to allow test-only subclassing in `SpyBookFileManager`
/// (LocalBookContentServiceTests). The dynamic-dispatch cost is
/// negligible — `fileUrl(for:)` is not on a hot path.
class BookFileManager {

    private let bookRegistry: TPPBookRegistryProvider
    private let accountsManager: AccountsManager
    private let fileManager: FileManager

    init(
        bookRegistry: TPPBookRegistryProvider = AppContainer.production().bookRegistry,
        accountsManager: AccountsManager = AppContainer.production().accountsManager,
        fileManager: FileManager = .default
    ) {
        self.bookRegistry = bookRegistry
        self.accountsManager = accountsManager
        self.fileManager = fileManager
    }

    // MARK: - File URL

    /// Convenience: looks the book up in the registry and resolves its URL
    /// under the current account. Returns nil if the book is unknown or the
    /// content directory can't be created.
    func fileUrl(for identifier: String) -> URL? {
        fileUrl(for: identifier, account: accountsManager.currentAccountId)
    }

    func fileUrl(for identifier: String, account: String?) -> URL? {
        guard let book = bookRegistry.book(forIdentifier: identifier) else {
            return nil
        }
        return fileUrl(for: book, account: account)
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

        return directoryURL
    }

    // MARK: - Path Extension

    /// File extension for the book's on-disk artefact. LCP audiobooks land
    /// as `.lcpa`, LCP PDFs as `.zip`, everything else as `.epub`. The LCP
    /// branches are compiled out of Palace-noDRM via `#if LCP`.
    func pathExtension(for book: TPPBook?) -> String {
        #if LCP
        if let book = book {
            if LCPAudiobooks.canOpenBook(book) {
                return "lcpa"
            }
            if LCPPDFs.canOpenBook(book) {
                return "zip"
            }
        }
        #endif
        return "epub"
    }
}
