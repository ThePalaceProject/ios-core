import UIKit
@testable import Palace
import PalaceBookModel

// `@unchecked Sendable`: `ImageCacheType` is now `Sendable` (Swift 6 Wave 1), so
// its conformers must be. Honest — all backing dictionaries/counters are accessed
// exclusively through the `sync { }` `NSLock` helper; `now` is a test-config knob
// set before concurrent use. `final` keeps the assertion subclass-proof.
// nonisolated: ImageCacheType moved into the Swift-6 PalaceBookModel package, which flips
// a conformer's inferred isolation (see production ImageCache/ImageLoader). This double is
// called off-main; explicit nonisolated keeps it off-main-safe (its own state, no MainActor API).
public nonisolated final class MockImageCache: ImageCacheType, @unchecked Sendable {
    private var store: [String: UIImage] = [:]
    private var expirations: [String: Date] = [:]

    public private(set) var setKeys: [String] = []
    public private(set) var removedKeys: [String] = []
    public private(set) var cleared: Bool = false

    public var now: Date = Date()

    /// Serializes access to the backing dictionaries. `ImageLoaderImpl.coverImage`
    /// awaits a MainActor hop then resumes on a Task scheduler thread before
    /// reading the cache — the call site is concurrent even though tests look
    /// sequential. Without this lock, COW-storage reads from one thread while
    /// the test setup mutations are still propagating from main can corrupt
    /// the bridge, producing `-[__NSTaggedDate objectForKey:]` crashes on CI
    /// under load. Production `ImageCache` is `OperationQueue`-serialized for
    /// the same reason; the mock has to match.
    private let lock = NSLock()
    private func sync<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }

    public func set(_ image: UIImage, for key: String, expiresIn: TimeInterval?) {
        sync {
            store[key] = image
            setKeys.append(key)
            if let ttl = expiresIn {
                expirations[key] = now.addingTimeInterval(ttl)
            } else {
                expirations[key] = nil
            }
        }
    }

    public func get(for key: String) -> UIImage? {
        sync {
            if let exp = expirations[key], exp < now {
                store.removeValue(forKey: key)
                expirations.removeValue(forKey: key)
                return nil
            }
            return store[key]
        }
    }

    public func getAsync(for key: String) async -> UIImage? {
        return get(for: key)
    }

    public func remove(for key: String) {
        sync {
            store.removeValue(forKey: key)
            expirations.removeValue(forKey: key)
            removedKeys.append(key)
        }
    }

    public func clear() {
        sync {
            store.removeAll()
            expirations.removeAll()
            cleared = true
        }
    }

    public func warmMemoryCache(for keys: [String]) async {
        // No-op for tests — promotion is implicit since get() already
        // returns from the in-memory store the mock holds.
        for key in keys { _ = get(for: key) }
    }

    public func evictDecodedImages() {}

    public func resetHistory() {
        sync {
            setKeys.removeAll()
            removedKeys.removeAll()
            cleared = false
        }
    }

    // MARK: - TenPrint Cover Generation for Snapshot Tests

    /// Generates a TenPrint-style book cover for deterministic snapshot testing
    /// Must be called from main thread as it uses UIKit views
    public static func generateTenPrintCover(title: String, author: String, size: CGSize = CGSize(width: 80, height: 120)) -> UIImage {
        // Ensure we're on the main thread for UIView operations
        if !Thread.isMainThread {
            var result: UIImage!
            DispatchQueue.main.sync {
                result = generateTenPrintCoverOnMainThread(title: title, author: author, size: size)
            }
            return result
        }
        return generateTenPrintCoverOnMainThread(title: title, author: author, size: size)
    }

    private static func generateTenPrintCoverOnMainThread(title: String, author: String, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2.0  // Fixed scale for consistent snapshot testing across devices
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { ctx in
                if let view = NYPLTenPrintCoverView(
                    frame: CGRect(origin: .zero, size: size),
                    withTitle: title,
                    withAuthor: author,
                    withScale: 0.4
                ) {
                    view.layer.render(in: ctx.cgContext)
                }
            }
    }

    /// Pre-populates the cache with TenPrint covers for the given books
    public func preloadTenPrintCovers(for books: [TPPBook]) {
        for book in books {
            let cover = MockImageCache.generateTenPrintCover(
                title: book.title,
                author: book.authors ?? "Unknown Author"
            )
            set(cover, for: book.identifier, expiresIn: nil)
        }
    }
}
