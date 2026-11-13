//  BookCoverStore.swift
//
//  Cover, thumbnail, loading flags and cover color for each book, keyed by
//  book ID (PP-5502). A loans sync builds a new TPPBook for every book; with
//  this state kept by ID the new objects reuse the decoded covers and colors
//  instead of reading the cache and computing the color again. The decoded
//  images are limited by bytes and released on a memory warning (PP-5583).

import Foundation
import UIKit

/// Cover state for one book ID.
struct BookCoverState {
    var coverImage: UIImage?
    var thumbnailImage: UIImage?
    var isCoverLoading = false
    var isThumbnailLoading = false
    var dominantColor: UIColor = .gray
    /// The image `dominantColor` was (or is being) computed from.
    var colorSource: UIImage?
    /// Set when the store released the cover or thumbnail. A getter then reads
    /// the image cache's memory copy, and the next cover keeps the color.
    var coverReleased = false
    var thumbnailReleased = false
    var colorKeptFromReleasedImage = false
}

/// An entry lives while at least one TPPBook object for its ID is alive.
/// A sync creates the replacement object before the registry releases the
/// old one, so the count does not reach zero and the cover is kept; once the
/// last object goes, the entry and its images are released.
///
/// Decoded images are also released while the entry lives: over
/// `Limits.byteLimit`, and on a memory warning. Neither touches the
/// `Limits.keepRecent` most recently read covers, because a view that drew a
/// cover reads it again on its next redraw and fetches only when it appears.
/// A release sends no change notice, so a drawn view keeps its frame.
// PUBLIC_INTENT: TPPBook's public init takes the store, so callers and tests can inject one.
public final class BookCoverStore: @unchecked Sendable {
    // PUBLIC_INTENT: default store for TPPBook's public init.
    public static let shared = BookCoverStore()

    private struct WeakBook {
        weak var book: TPPBook?
    }

    private struct Entry {
        var state = BookCoverState()
        var books: [ObjectIdentifier: WeakBook] = [:]
        /// `readClock` value of the last getter read or new image.
        var lastUsed: UInt64 = 0
    }

    /// Recursive: a TPPBook's deinit unregisters, and the last strong
    /// reference to a book can be dropped on any thread, including one that
    /// already holds this lock.
    private let lock = NSRecursiveLock()
    private var entries: [String: Entry] = [:]
    private var readClock: UInt64 = 0

    let colorQueue: DispatchQueue
    private let colorExtractor: @Sendable (UIImage) -> UIColor
    let limits: Limits

    init(
        colorQueue: DispatchQueue = DispatchQueue(label: "org.thepalaceproject.dominantcolor", qos: .utility),
        colorExtractor: @escaping @Sendable (UIImage) -> UIColor = { DominantCoverColor.extract(from: $0) },
        limits: Limits = .forDevice()
    ) {
        self.colorQueue = colorQueue
        self.colorExtractor = colorExtractor
        self.limits = limits
    }

    /// How many decoded image bytes the store keeps, and how many of the most
    /// recently read covers it never releases.
    struct Limits: Equatable, Sendable {
        let byteLimit: Int
        let keepRecent: Int

        /// Byte limits match `ImageCache`'s decoded-image tiers. `keepRecent` is
        /// about two screens of covers: a phone catalog or My Books screen, or
        /// an iPad catalog with several lanes.
        static func forDevice(memoryMB: UInt64 = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)) -> Limits {
            let mb = 1024 * 1024
            if memoryMB < 2048 {
                return Limits(byteLimit: 15 * mb, keepRecent: 40)
            } else if memoryMB < 4096 {
                return Limits(byteLimit: 25 * mb, keepRecent: 40)
            }
            return Limits(byteLimit: 40 * mb, keepRecent: 80)
        }
    }

    /// Releases every decoded image outside the `keepRecent` most recently read
    /// covers, for a memory warning. Loading flags and colors stay.
    // PUBLIC_INTENT: the app registers this as a memory warning release step.
    public func releaseImages() {
        lock.withLock {
            for identifier in releasableIdentifiersLocked() {
                releaseImagesLocked(for: identifier)
            }
        }
    }

    /// The cover for a getter: marks the entry as read, and says whether the
    /// store released the cover.
    func readCover(for identifier: String) -> (image: UIImage?, released: Bool) {
        lock.withLock {
            guard let state = markUsedLocked(identifier) else { return (nil, false) }
            return (state.coverImage, state.coverReleased)
        }
    }

    /// The thumbnail for a getter; see `readCover(for:)`.
    func readThumbnail(for identifier: String) -> (image: UIImage?, released: Bool) {
        lock.withLock {
            guard let state = markUsedLocked(identifier) else { return (nil, false) }
            return (state.thumbnailImage, state.thumbnailReleased)
        }
    }

    // MARK: - Live objects

    func register(_ book: TPPBook, for identifier: String) {
        lock.withLock {
            entries[identifier, default: Entry()].books[ObjectIdentifier(book)] = WeakBook(book: book)
        }
    }

    func unregister(_ book: ObjectIdentifier, for identifier: String) {
        lock.withLock {
            guard var entry = entries.removeValue(forKey: identifier) else { return }
            entry.books[book] = nil
            if !entry.books.isEmpty {
                entries[identifier] = entry
            }
        }
    }

    func liveObjectCount(for identifier: String) -> Int {
        lock.withLock { entries[identifier]?.books.count ?? 0 }
    }

    /// Bytes of the decoded images the store holds now (PP-5509). An image held
    /// in more than one field counts once. Walks every entry, so it is meant for
    /// the memory event line, not a hot path.
    // PUBLIC_INTENT: read by the app's memory event line.
    public var imageByteCount: Int {
        lock.withLock { imageByteCountLocked() }
    }

    /// `imageByteCount` of the default store that TPPBook uses.
    // PUBLIC_INTENT: read by the app's memory event line.
    public static var defaultStoreImageByteCount: Int { shared.imageByteCount }

    var entryCount: Int {
        lock.withLock { entries.count }
    }

    // MARK: - State

    func state(for identifier: String) -> BookCoverState {
        lock.withLock { entries[identifier]?.state ?? BookCoverState() }
    }

    /// Applies `change` to the state for `identifier` and notifies every live
    /// object for that ID. Does nothing when no object for the ID is alive.
    ///
    /// On the main thread the objects get `objectWillChange` before the change,
    /// as `@Published` does. Off the main thread the change is applied at once
    /// and the notices follow on the main thread, so observers stay on main.
    func update(_ identifier: String, _ change: (inout BookCoverState) -> Void) {
        guard Thread.isMainThread else {
            guard apply(change, to: identifier) else { return }
            DispatchQueue.main.async { [self] in
                let books = liveBooks(for: identifier)
                books.forEach { $0.coverStateWillChange() }
                books.forEach { $0.coverStateDidChange() }
            }
            return
        }
        let books = liveBooks(for: identifier)
        books.forEach { $0.coverStateWillChange() }
        guard apply(change, to: identifier) else { return }
        books.forEach { $0.coverStateDidChange() }
    }

    /// Stores `image` as the cover unless it ranks below the stored cover, and
    /// computes the color of an accepted cover. Views of different sizes fetch
    /// into the same entry, so a lane-sized decode must not replace the detail
    /// header's larger one. `endingLoad` also clears `isCoverLoading`.
    /// Explicit assignment (`TPPBook.coverImage = …`, `clearCachedImages`) is
    /// not limited this way.
    func offerCover(_ image: UIImage?, for identifier: String, endingLoad: Bool = false) {
        var accepted: UIImage?
        update(identifier) { state in
            if endingLoad {
                state.isCoverLoading = false
            }
            guard let image else { return }
            if let current = state.coverImage, Self.image(image, ranksBelow: current) { return }
            state.coverImage = image
            accepted = image
        }
        if let accepted {
            updateDominantColor(for: identifier, using: accepted)
        }
    }

    /// A generated placeholder ranks below any real cover, whatever its size: a
    /// TenPrint drawn at display size can have more pixels than a capped real
    /// decode. Between two of the same kind, fewer pixels ranks below.
    static func image(_ candidate: UIImage, ranksBelow current: UIImage) -> Bool {
        if candidate.isGeneratedCoverPlaceholder != current.isGeneratedCoverPlaceholder {
            return candidate.isGeneratedCoverPlaceholder
        }
        return candidate.pixelCount < current.pixelCount
    }

    /// Computes the cover color from `image` unless the stored color already
    /// came from this image object, then stores it.
    /// After a release the color stays: the cover that comes back is the same
    /// cover, so it takes the color over without computing it again.
    func updateDominantColor(for identifier: String, using image: UIImage) {
        let claimed = lock.withLock { () -> Bool in
            guard let entry = entries[identifier], entry.state.colorSource !== image else { return false }
            entries[identifier]?.state.colorSource = image
            if entry.state.colorKeptFromReleasedImage {
                entries[identifier]?.state.colorKeptFromReleasedImage = false
                return false
            }
            return true
        }
        guard claimed else { return }

        colorQueue.async { [self] in
            let color = colorExtractor(image)
            DispatchQueue.main.async { [self] in
                // A newer image may have claimed the color while this one was computed.
                guard state(for: identifier).colorSource === image else { return }
                update(identifier) { $0.dominantColor = color }
            }
        }
    }

    // MARK: - Private

    private func apply(_ change: (inout BookCoverState) -> Void, to identifier: String) -> Bool {
        lock.withLock {
            guard var entry = entries.removeValue(forKey: identifier) else { return false }
            let before = (cover: entry.state.coverImage, thumbnail: entry.state.thumbnailImage)
            change(&entry.state)
            let newCover = entry.state.coverImage.map { $0 !== before.cover } ?? false
            let newThumbnail = entry.state.thumbnailImage.map { $0 !== before.thumbnail } ?? false
            if newCover { entry.state.coverReleased = false }
            if newThumbnail { entry.state.thumbnailReleased = false }
            if newCover || newThumbnail {
                // A new image is about to be drawn: count it as read so the
                // byte limit does not release it first.
                readClock += 1
                entry.lastUsed = readClock
            }
            entries[identifier] = entry
            if newCover || newThumbnail {
                enforceByteLimitLocked()
            }
            return true
        }
    }

    private func markUsedLocked(_ identifier: String) -> BookCoverState? {
        guard entries[identifier] != nil else { return nil }
        readClock += 1
        entries[identifier]?.lastUsed = readClock
        return entries[identifier]?.state
    }

    /// Entries holding an image, least recently used first, without the
    /// `keepRecent` most recently used ones.
    private func releasableIdentifiersLocked() -> [String] {
        let holding = entries
            .filter { $0.value.state.coverImage != nil || $0.value.state.thumbnailImage != nil || $0.value.state.colorSource != nil }
            .sorted { $0.value.lastUsed > $1.value.lastUsed }
        return holding.dropFirst(max(0, limits.keepRecent)).reversed().map(\.key)
    }

    private func enforceByteLimitLocked() {
        var bytes = imageByteCountLocked()
        guard bytes > limits.byteLimit else { return }
        for identifier in releasableIdentifiersLocked() {
            bytes -= releaseImagesLocked(for: identifier)
            if bytes <= limits.byteLimit { return }
        }
    }

    /// Returns the bytes of the images it released.
    @discardableResult
    private func releaseImagesLocked(for identifier: String) -> Int {
        guard var state = entries[identifier]?.state else { return 0 }
        let released = Self.byteCount(of: [state.coverImage, state.thumbnailImage, state.colorSource])
        if state.coverImage != nil { state.coverReleased = true }
        if state.thumbnailImage != nil { state.thumbnailReleased = true }
        if state.colorSource != nil { state.colorKeptFromReleasedImage = true }
        state.coverImage = nil
        state.thumbnailImage = nil
        state.colorSource = nil
        entries[identifier]?.state = state
        return released
    }

    private func imageByteCountLocked() -> Int {
        Self.byteCount(of: entries.values.flatMap { [$0.state.coverImage, $0.state.thumbnailImage, $0.state.colorSource] })
    }

    /// Decoded bytes of `images`, each image object counted once.
    private static func byteCount(of images: [UIImage?]) -> Int {
        var seen = Set<ObjectIdentifier>()
        var bytes = 0
        for image in images {
            guard let image, seen.insert(ObjectIdentifier(image)).inserted, let cgImage = image.cgImage else { continue }
            bytes += cgImage.bytesPerRow * cgImage.height
        }
        return bytes
    }

    private func liveBooks(for identifier: String) -> [TPPBook] {
        lock.withLock { entries[identifier]?.books.values.compactMap(\.book) ?? [] }
    }
}

private extension UIImage {
    var pixelCount: CGFloat {
        if let cgImage {
            return CGFloat(cgImage.width * cgImage.height)
        }
        return size.width * scale * size.height * scale
    }
}
