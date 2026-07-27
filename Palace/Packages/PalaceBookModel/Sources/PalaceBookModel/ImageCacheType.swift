import UIKit

public protocol ImageCacheType: Sendable {
    func set(_ image: UIImage, for key: String, expiresIn: TimeInterval?)
    func get(for key: String) -> UIImage?
    func getAsync(for key: String) async -> UIImage?
    func remove(for key: String)
    func clear()
    func warmMemoryCache(for keys: [String]) async
}

public extension ImageCacheType {
    func set(_ image: UIImage, for key: String) {
        let sevenDays: TimeInterval = 7 * 24 * 60 * 60
        set(image, for: key, expiresIn: sevenDays)
    }
}
