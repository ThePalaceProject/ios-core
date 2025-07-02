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
}
