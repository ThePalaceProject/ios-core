import UIKit

public protocol ImageCacheType: Sendable {
    func set(_ image: UIImage, for key: String, expiresIn: TimeInterval?)
    func get(for key: String) -> UIImage?
    func getAsync(for key: String) async -> UIImage?
    func remove(for key: String)
    func clear()
    func warmMemoryCache(for keys: [String]) async
    /// Drop the decoded (in-memory) image representations while keeping the
    /// compressed on-disk cache, so a re-decode is fast. Called on an account
    /// switch (the new library has different covers). Wave 3 S3 promoted this
    /// from a concrete `ImageCache`-only method to the protocol so the
    /// account-switch cleanup can invoke it through the injected `ImageCacheType`
    /// seam instead of reaching for `ImageCache.shared`.
    func evictDecodedImages()
}

public extension ImageCacheType {
    func set(_ image: UIImage, for key: String) {
        let sevenDays: TimeInterval = 7 * 24 * 60 * 60
        set(image, for: key, expiresIn: sevenDays)
    }
}
