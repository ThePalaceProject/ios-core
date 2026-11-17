import UIKit

public protocol ImageCacheType: Sendable {
    func set(_ image: UIImage, for key: String, expiresIn: TimeInterval?)
    /// Stores one image under several keys. A disk-backed cache encodes and
    /// writes the image once and makes the other keys name the same stored
    /// data.
    func set(_ image: UIImage, for keys: [String], expiresIn: TimeInterval?)
    func get(for key: String) -> UIImage?
    func getAsync(for key: String) async -> UIImage?
    func remove(for key: String)
    func clear()
    func warmMemoryCache(for keys: [String]) async
    /// Drop the decoded (in-memory) image representations while keeping the
    /// compressed on-disk cache, so a re-decode is fast. Called on an account
    /// switch (the new library has different covers). On the protocol so the
    /// account-switch cleanup does not need `ImageCache.shared`.
    func evictDecodedImages()
    /// The decoded image for `key` if it is in memory now. Never reads disk.
    func memoryImage(for key: String) -> UIImage?
}

public extension ImageCacheType {
    func memoryImage(for key: String) -> UIImage? { nil }

    func set(_ image: UIImage, for keys: [String], expiresIn: TimeInterval?) {
        for key in keys {
            set(image, for: key, expiresIn: expiresIn)
        }
    }

    func set(_ image: UIImage, for keys: [String]) {
        let sevenDays: TimeInterval = 7 * 24 * 60 * 60
        set(image, for: keys, expiresIn: sevenDays)
    }

    func set(_ image: UIImage, for key: String) {
        let sevenDays: TimeInterval = 7 * 24 * 60 * 60
        set(image, for: key, expiresIn: sevenDays)
    }
}
