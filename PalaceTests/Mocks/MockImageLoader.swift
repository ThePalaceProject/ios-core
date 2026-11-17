import UIKit
@testable import Palace
import PalaceBookModel

/// In-memory test double for the `ImageLoading` protocol. Records the calls it
/// receives so tests can assert routing without depending on the live actor,
/// disk cache, or network.
// nonisolated + @unchecked Sendable: ImageLoading moved into the Swift-6 PalaceBookModel
// package, flipping a conformer's inferred isolation. nonisolated keeps this double off-main-safe
// (its own in-memory state; the test drives threading) and matches production ImageLoader.
public nonisolated final class MockImageLoader: ImageLoading, @unchecked Sendable {

    // MARK: - Locked state
    //
    // The test host's own catalog loads covers through the global loader on
    // background tasks while a test reads these logs on main, so every field
    // goes through `lock`.

    private let lock = NSLock()
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private var _stubbedCoverImage: UIImage?
    private var _stubbedThumbnailImage: UIImage?
    private var _stubbedPlayerCoverImage: UIImage?
    /// Backing store for `get`/`set`/`getAsync` so tests can preload entries.
    private var store: [String: UIImage] = [:]
    private var _coverCalls: [CoverCall] = []
    private var _thumbnailCalls: [ThumbnailCall] = []
    private var _playerCoverCalls: [String] = []
    private var _setKeys: [String] = []
    private var _removedKeys: [String] = []
    private var _warmedKeys: [[String]] = []
    private var _clearAllCount = 0
    private var _evictDecodedCount = 0
    private var heldSizedCoverIdentifier: String?
    private var sizedCoverReleased = true
    private var heldSizedCoverWaiters: [CheckedContinuation<Void, Never>] = []

    // MARK: - Configurable returns

    /// If set, `coverImage(for:)` and `coverImage(for:displayPoints:)` return this.
    public var stubbedCoverImage: UIImage? {
        get { locked { _stubbedCoverImage } }
        set { locked { _stubbedCoverImage = newValue } }
    }
    /// If set, `thumbnailImage(for:)` returns this.
    public var stubbedThumbnailImage: UIImage? {
        get { locked { _stubbedThumbnailImage } }
        set { locked { _stubbedThumbnailImage = newValue } }
    }
    /// If set, `playerCoverImage(for:)` returns this; otherwise falls back to `stubbedCoverImage`.
    public var stubbedPlayerCoverImage: UIImage? {
        get { locked { _stubbedPlayerCoverImage } }
        set { locked { _stubbedPlayerCoverImage = newValue } }
    }

    // MARK: - Call records

    public struct CoverCall: Equatable {
        public let identifier: String
        public let displayPoints: CGFloat?
        public let isCompletion: Bool
    }

    public struct ThumbnailCall: Equatable {
        public let identifier: String
        public let isCompletion: Bool
    }

    public var coverCalls: [CoverCall] { locked { _coverCalls } }
    public var thumbnailCalls: [ThumbnailCall] { locked { _thumbnailCalls } }
    public var playerCoverCalls: [String] { locked { _playerCoverCalls } }

    public var setKeys: [String] { locked { _setKeys } }
    public var removedKeys: [String] { locked { _removedKeys } }
    public var warmedKeys: [[String]] { locked { _warmedKeys } }
    public var clearAllCount: Int { locked { _clearAllCount } }
    public var evictDecodedCount: Int { locked { _evictDecodedCount } }

    public init() {}

    // MARK: - Holding a sized fetch open

    /// Suspends `coverImage(for:displayPoints:)` for `identifier` until
    /// `releaseSizedCover()`, so a test can observe the in-flight state.
    public func holdSizedCover(for identifier: String) {
        locked {
            heldSizedCoverIdentifier = identifier
            sizedCoverReleased = false
        }
    }

    public func releaseSizedCover() {
        let waiters: [CheckedContinuation<Void, Never>] = locked {
            sizedCoverReleased = true
            defer { heldSizedCoverWaiters = [] }
            return heldSizedCoverWaiters
        }
        waiters.forEach { $0.resume() }
    }

    // MARK: - ImageLoading conformance

    public func coverImage(for book: TPPBook) async -> UIImage? {
        locked {
            _coverCalls.append(.init(identifier: book.identifier, displayPoints: nil, isCompletion: false))
            return _stubbedCoverImage
        }
    }

    public func coverImage(for book: TPPBook, displayPoints: CGFloat) async -> UIImage? {
        let identifier = book.identifier
        let mustWait = locked {
            _coverCalls.append(.init(identifier: identifier, displayPoints: displayPoints, isCompletion: false))
            return heldSizedCoverIdentifier == identifier && !sizedCoverReleased
        }
        if mustWait {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                let resumeNow = locked {
                    if sizedCoverReleased { return true }
                    heldSizedCoverWaiters.append(waiter)
                    return false
                }
                if resumeNow { waiter.resume() }
            }
        }
        return stubbedCoverImage
    }

    public func thumbnailImage(for book: TPPBook) async -> UIImage? {
        locked {
            _thumbnailCalls.append(.init(identifier: book.identifier, isCompletion: false))
            return _stubbedThumbnailImage
        }
    }

    public func playerCoverImage(for book: TPPBook) async -> UIImage? {
        locked {
            _playerCoverCalls.append(book.identifier)
            return _stubbedPlayerCoverImage ?? _stubbedCoverImage
        }
    }

    public func coverImage(for book: TPPBook, completion: @escaping (UIImage?) -> Void) {
        let img = locked {
            _coverCalls.append(.init(identifier: book.identifier, displayPoints: nil, isCompletion: true))
            return _stubbedCoverImage
        }
        // Swift 6: the non-Sendable `completion` is "sent" into the @Sendable
        // main-queue closure. Box it so the crossing is a Sendable value.
        let boxed = SendableCompletion(completion)
        DispatchQueue.main.async { boxed.run(img) }
    }

    public func thumbnailImage(for book: TPPBook, completion: @escaping (UIImage?) -> Void) {
        let img = locked {
            _thumbnailCalls.append(.init(identifier: book.identifier, isCompletion: true))
            return _stubbedThumbnailImage
        }
        let boxed = SendableCompletion(completion)
        DispatchQueue.main.async { boxed.run(img) }
    }

    /// `@unchecked Sendable` wrapper so a non-Sendable `(UIImage?) -> Void`
    /// completion can be handed to a `@Sendable` main-queue closure. The
    /// wrapped closure only runs on the main queue (invoked once inside
    /// `DispatchQueue.main.async`), so the crossing is safe.
    private struct SendableCompletion: @unchecked Sendable {
        private let body: (UIImage?) -> Void
        init(_ body: @escaping (UIImage?) -> Void) { self.body = body }
        func run(_ image: UIImage?) { body(image) }
    }

    public func get(for key: String) -> UIImage? {
        locked { store[key] }
    }

    public func getAsync(for key: String) async -> UIImage? {
        locked { store[key] }
    }

    public func set(_ image: UIImage, for key: String, expiresIn: TimeInterval?) {
        locked {
            store[key] = image
            _setKeys.append(key)
        }
    }

    public func remove(for key: String) {
        locked {
            store.removeValue(forKey: key)
            _removedKeys.append(key)
        }
    }

    public func clearAll() {
        locked {
            store.removeAll()
            _clearAllCount += 1
        }
    }

    public func evictDecodedImages() {
        locked { _evictDecodedCount += 1 }
    }

    public func warmMemoryCache(for keys: [String]) async {
        locked { _warmedKeys.append(keys) }
    }

    // MARK: - Convenience for tests

    public func resetHistory() {
        locked {
            _coverCalls.removeAll()
            _thumbnailCalls.removeAll()
            _playerCoverCalls.removeAll()
            _setKeys.removeAll()
            _removedKeys.removeAll()
            _warmedKeys.removeAll()
            _clearAllCount = 0
            _evictDecodedCount = 0
        }
    }
}
