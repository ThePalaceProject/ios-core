//
//  DiskBudgetManager.swift
//  Palace
//
//  Owns the LRU eviction state machine for the per-account content
//  directory. Extracted from MyBooksDownloadCenter so the file-system /
//  budget logic can be exercised end-to-end with a temp-dir FileManager
//  and a registry mock, without standing up a full download center.
//
//  MyBooksDownloadCenter still exposes the same `enforceContentDiskBudgetIfNeeded`
//  and `performDiskBudgetEviction` API surface — those methods now delegate
//  here, so the existing 7 eviction tests + the TPPAppDelegate caller keep
//  working unchanged.
//

import Foundation
import UIKit
import PalaceLogging
import PalaceBookRegistry

/// Resolves the "is this an iPhone SE/8-class (small) device" flag without
/// touching the main-actor-isolated `UIScreen.main` from a background thread.
///
/// The production default for `DiskBudgetManager.isSmallDevice` used to read
/// `UIScreen.main.nativeBounds.height` inline; under Swift 6 `complete`-mode
/// that is a main-actor-isolated access, and it was in fact already being
/// evaluated off-main (the eviction entrypoint runs on `TPPAppDelegate`'s
/// background `monitorQueue`). This holder resolves the pixel height exactly
/// once, hopping to the main actor when necessary, and caches it under a lock.
/// Screen native bounds don't change at runtime, so a one-shot cache preserves
/// the original `<= 1334` threshold behavior exactly.
///
/// - Sendable invariant: the only mutable state (`cachedHeight`) is read and
///   written solely under `lock`; `@unchecked` because `CGFloat`'s optional
///   box isn't expressible as a stored `Sendable` without the lock contract.
private final class SmallDeviceResolver: @unchecked Sendable {
    static let shared = SmallDeviceResolver()

    private let lock = NSLock()
    private var cachedHeight: CGFloat?

    /// iPhone 6/7/8/SE-class devices report a native height of 1334 px or less.
    func isSmallDevice() -> Bool {
        lock.lock()
        if let height = cachedHeight {
            lock.unlock()
            return height <= 1334
        }
        lock.unlock()

        let resolved: CGFloat
        if Thread.isMainThread {
            resolved = MainActor.assumeIsolated { UIScreen.main.nativeBounds.height }
        } else {
            resolved = DispatchQueue.main.sync { UIScreen.main.nativeBounds.height }
        }

        lock.lock()
        cachedHeight = resolved
        lock.unlock()
        return resolved <= 1334
    }
}

/// Reclaims disk space under the per-account content directory by evicting
/// least-recently-used files until total usage + the anticipated next-write
/// fits under the budget. Atomically flips evicted books' registry records
/// to `.downloadNeeded` so the UI doesn't keep showing a "Read" button for
/// content that's no longer on disk.
final class DiskBudgetManager {

    private let bookRegistry: TPPBookRegistryProvider
    private let accountsManager: AccountsManager
    private let bookFileManager: BookFileManager
    private let fileManager: FileManager

    /// Test seam for the small-device branch in `defaultDiskBudgetBytes`.
    /// Production passes the default closure (UIScreen native bounds), so
    /// behavior preserved exactly. Tests substitute a fixed value.
    private let isSmallDevice: () -> Bool

    init(
        bookRegistry: TPPBookRegistryProvider = AppContainer.production().bookRegistry,
        accountsManager: AccountsManager = AppContainer.production().accountsManager,
        bookFileManager: BookFileManager? = nil,
        fileManager: FileManager = .default,
        isSmallDevice: @escaping () -> Bool = { SmallDeviceResolver.shared.isSmallDevice() }
    ) {
        self.bookRegistry = bookRegistry
        self.accountsManager = accountsManager
        self.bookFileManager = bookFileManager ?? BookFileManager(
            bookRegistry: bookRegistry,
            accountsManager: accountsManager,
            fileManager: fileManager
        )
        self.fileManager = fileManager
        self.isSmallDevice = isSmallDevice
    }

    // MARK: - Public entrypoints

    /// Top-level call gate. Resolves the current account's content directory
    /// and runs eviction with the production default budget.
    func enforceContentDiskBudgetIfNeeded(adding bytesToAdd: Int64) {
        guard let dir = bookFileManager.contentDirectoryURL(accountsManager.currentAccountId) else { return }
        performDiskBudgetEviction(in: dir, adding: bytesToAdd, budgetOverrideBytes: nil)
    }

    /// Evicts least-recently-used content files from `dir` until total usage
    /// + `bytesToAdd` fits under the budget. For every evicted file that
    /// maps to a book in `bookRegistry`, flips that book's state to
    /// `.downloadNeeded` atomically with the deletion so the UI doesn't keep
    /// showing a "Read" button for content that's no longer on disk.
    ///
    /// Before this was wired to the registry, eviction was silent — the
    /// registry kept `.downloadSuccessful` in memory and on disk until the
    /// next `BookRegistrySync.load()` ran file-existence reconciliation on
    /// cold launch or library switch. That's why previously-downloaded
    /// titles only flipped to "Download Needed" on quit/relaunch.
    ///
    /// `budgetOverrideBytes` is a test seam. Production calls pass `nil`,
    /// which defaults to 1.2 GB on small devices (iPhone 8-class) and 2.5 GB
    /// elsewhere.
    func performDiskBudgetEviction(
        in dir: URL,
        adding bytesToAdd: Int64,
        budgetOverrideBytes: Int64?
    ) {
        let budgetBytes: Int64 = budgetOverrideBytes ?? defaultDiskBudgetBytes()

        let currentUsage = directoryUsageBytes(at: dir)
        var neededFree = (currentUsage + bytesToAdd) - budgetBytes
        guard neededFree > 0 else { return }

        // Build a hashedIdentifier → bookIdentifier map from the registry so we can flip
        // each evicted book's state in the same pass as the file deletion. Without this,
        // the registry keeps .downloadSuccessful and the user only sees the revert on the
        // next cold launch (BookRegistrySync.load() file-existence reconciliation).
        var hashToIdentifier = [String: String]()
        for book in bookRegistry.myBooks {
            hashToIdentifier[book.identifier.sha256()] = book.identifier
        }

        let files = listContentFilesSortedByLRU(in: dir)
        var evictedCount = 0
        var evictedBytesTotal: Int64 = 0
        for url in files {
            if neededFree <= 0 { break }
            // Never delete LCP license/content files during eviction
            let ext = url.pathExtension.lowercased()
            if ext == "lcpl" || ext == "lcpa" { continue }
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                Log.error(#file, "LRU eviction: failed to remove \(url.lastPathComponent): \(error.localizedDescription)")
                continue
            }
            neededFree -= Int64(size)
            evictedCount += 1
            evictedBytesTotal += Int64(size)

            // Reverse-lookup the book from the filename. File naming is
            // `book.identifier.sha256() + "." + pathExtension(for: book)`
            // (see BookFileManager.fileUrl(for:account:)), so the base name
            // without extension is the hashed identifier.
            let hashedIdentifier = url.deletingPathExtension().lastPathComponent
            if let identifier = hashToIdentifier[hashedIdentifier] {
                bookRegistry.setState(.downloadNeeded, for: identifier)
                Log.warn(#file, "LRU eviction: removed '\(identifier)' (\(size) bytes) — registry flipped to .downloadNeeded")
            } else {
                Log.warn(#file, "LRU eviction: removed orphan file \(url.lastPathComponent) (\(size) bytes) — no matching registry record")
            }
        }

        if evictedCount > 0 {
            Log.info(#file, "LRU eviction complete: \(evictedCount) file(s), \(evictedBytesTotal) bytes reclaimed")
        }
    }

    // MARK: - Budget + usage helpers

    /// Per-device default budget. Small (iPhone 6/7/8-class) devices get
    /// ~1.2 GB; everything else ~2.5 GB.
    func defaultDiskBudgetBytes() -> Int64 {
        return isSmallDevice() ? (1_200 * 1024 * 1024) : (2_500 * 1024 * 1024)
    }

    /// Total bytes used under the *current* account's content directory.
    /// Returns 0 if the directory can't be resolved.
    func contentDirectoryUsageBytes() -> Int64 {
        guard let dir = bookFileManager.contentDirectoryURL(accountsManager.currentAccountId) else { return 0 }
        return directoryUsageBytes(at: dir)
    }

    /// Total bytes used under `dir` (non-recursive — the content dir is
    /// flat). Skips hidden files; missing files report 0.
    func directoryUsageBytes(at dir: URL) -> Int64 {
        guard let contents = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for url in contents {
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize { total += Int64(size) }
        }
        return total
    }

    /// Files in the *current* account's content directory, sorted oldest-
    /// to-newest by content-access date (or modification date as fallback).
    func listContentFilesSortedByLRU() -> [URL] {
        guard let dir = bookFileManager.contentDirectoryURL(accountsManager.currentAccountId) else { return [] }
        return listContentFilesSortedByLRU(in: dir)
    }

    /// Same as the no-arg variant but for an explicit directory (used by
    /// `performDiskBudgetEviction` to operate on the directory it just
    /// resolved at the call site, avoiding a second resolve).
    func listContentFilesSortedByLRU(in dir: URL) -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentAccessDateKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        return contents.sorted { a, b in
            let ra = try? a.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey])
            let rb = try? b.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey])
            let da = ra?.contentAccessDate ?? ra?.contentModificationDate ?? Date.distantPast
            let db = rb?.contentAccessDate ?? rb?.contentModificationDate ?? Date.distantPast
            return da < db
        }
    }
}
