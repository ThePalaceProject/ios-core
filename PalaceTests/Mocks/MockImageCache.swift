import UIKit
@testable import Palace

public final class MockImageCache: ImageCacheType {
    private var store: [String: UIImage] = [:]
    private var expirations: [String: Date] = [:]

    public private(set) var setKeys: [String] = []
    public private(set) var removedKeys: [String] = []
    public private(set) var cleared: Bool = false

    public var now: Date = Date()

    public func set(_ image: UIImage, for key: String, expiresIn: TimeInterval?) {
        store[key] = image
        setKeys.append(key)
        if let ttl = expiresIn {
            expirations[key] = now.addingTimeInterval(ttl)
        } else {
            expirations[key] = nil
        }
    }

    public func get(for key: String) -> UIImage? {
        if let exp = expirations[key], exp < now {
            store.removeValue(forKey: key)
            expirations.removeValue(forKey: key)
            return nil
        }
        return store[key]
    }

    public func remove(for key: String) {
        store.removeValue(forKey: key)
        expirations.removeValue(forKey: key)
        removedKeys.append(key)
    }

    public func clear() {
        store.removeAll()
        expirations.removeAll()
        cleared = true
    }

    public func resetHistory() {
        setKeys.removeAll()
        removedKeys.removeAll()
        cleared = false
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
