//  BookCoverStore.swift
//
//  Cover, thumbnail, loading flags and cover color for each book, keyed by
//  book ID (PP-5502). A loans sync builds a new TPPBook for every book; with
//  this state kept by ID the new objects reuse the decoded covers and colors
//  instead of reading the cache and computing the color again.

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
}

/// An entry lives while at least one TPPBook object for its ID is alive.
/// A sync creates the replacement object before the registry releases the
/// old one, so the count does not reach zero and the cover is kept; once the
/// last object goes, the entry and its images are released.
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
    }

    /// Recursive: a TPPBook's deinit unregisters, and the last strong
    /// reference to a book can be dropped on any thread, including one that
    /// already holds this lock.
    private let lock = NSRecursiveLock()
    private var entries: [String: Entry] = [:]

    let colorQueue: DispatchQueue
    private let colorExtractor: @Sendable (UIImage) -> UIColor

    init(
        colorQueue: DispatchQueue = DispatchQueue(label: "org.thepalaceproject.dominantcolor", qos: .utility),
        colorExtractor: @escaping @Sendable (UIImage) -> UIColor = { DominantCoverColor.extract(from: $0) }
    ) {
        self.colorQueue = colorQueue
        self.colorExtractor = colorExtractor
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
        lock.withLock {
            var seen = Set<ObjectIdentifier>()
            var bytes = 0
            for entry in entries.values {
                for image in [entry.state.coverImage, entry.state.thumbnailImage, entry.state.colorSource] {
                    guard let image, seen.insert(ObjectIdentifier(image)).inserted, let cgImage = image.cgImage else { continue }
                    bytes += cgImage.bytesPerRow * cgImage.height
                }
            }
            return bytes
        }
    }

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
    func updateDominantColor(for identifier: String, using image: UIImage) {
        let claimed = lock.withLock { () -> Bool in
            guard let entry = entries[identifier], entry.state.colorSource !== image else { return false }
            entries[identifier]?.state.colorSource = image
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
            change(&entry.state)
            entries[identifier] = entry
            return true
        }
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
