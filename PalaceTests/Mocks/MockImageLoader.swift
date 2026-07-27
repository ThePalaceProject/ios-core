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

    // MARK: - Configurable returns

    /// If set, `coverImage(for:)` and `coverImage(for:displayPoints:)` return this.
    public var stubbedCoverImage: UIImage?
    /// If set, `thumbnailImage(for:)` returns this.
    public var stubbedThumbnailImage: UIImage?
    /// If set, `playerCoverImage(for:)` returns this; otherwise falls back to `stubbedCoverImage`.
    public var stubbedPlayerCoverImage: UIImage?
    /// Backing store for `get`/`set`/`getAsync` so tests can preload entries.
    private var store: [String: UIImage] = [:]

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

    public private(set) var coverCalls: [CoverCall] = []
    public private(set) var thumbnailCalls: [ThumbnailCall] = []
    public private(set) var playerCoverCalls: [String] = []

    public private(set) var setKeys: [String] = []
    public private(set) var removedKeys: [String] = []
    public private(set) var warmedKeys: [[String]] = []
    public private(set) var clearAllCount: Int = 0
    public private(set) var evictDecodedCount: Int = 0

    public init() {}

    // MARK: - ImageLoading conformance

    public func coverImage(for book: TPPBook) async -> UIImage? {
        coverCalls.append(.init(identifier: book.identifier, displayPoints: nil, isCompletion: false))
        return stubbedCoverImage
    }

    public func coverImage(for book: TPPBook, displayPoints: CGFloat) async -> UIImage? {
        coverCalls.append(.init(identifier: book.identifier, displayPoints: displayPoints, isCompletion: false))
        return stubbedCoverImage
    }

    public func thumbnailImage(for book: TPPBook) async -> UIImage? {
        thumbnailCalls.append(.init(identifier: book.identifier, isCompletion: false))
        return stubbedThumbnailImage
    }

    public func playerCoverImage(for book: TPPBook) async -> UIImage? {
        playerCoverCalls.append(book.identifier)
        return stubbedPlayerCoverImage ?? stubbedCoverImage
    }

    public func coverImage(for book: TPPBook, completion: @escaping (UIImage?) -> Void) {
        coverCalls.append(.init(identifier: book.identifier, displayPoints: nil, isCompletion: true))
        let img = stubbedCoverImage
        // Swift 6: the non-Sendable `completion` is "sent" into the @Sendable
        // main-queue closure. Box it so the crossing is a Sendable value.
        let boxed = SendableCompletion(completion)
        DispatchQueue.main.async { boxed.run(img) }
    }

    public func thumbnailImage(for book: TPPBook, completion: @escaping (UIImage?) -> Void) {
        thumbnailCalls.append(.init(identifier: book.identifier, isCompletion: true))
        let img = stubbedThumbnailImage
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
        store[key]
    }

    public func getAsync(for key: String) async -> UIImage? {
        store[key]
    }

    public func set(_ image: UIImage, for key: String, expiresIn: TimeInterval?) {
        store[key] = image
        setKeys.append(key)
    }

    public func remove(for key: String) {
        store.removeValue(forKey: key)
        removedKeys.append(key)
    }

    public func clearAll() {
        store.removeAll()
        clearAllCount += 1
    }

    public func evictDecodedImages() {
        evictDecodedCount += 1
    }

    public func warmMemoryCache(for keys: [String]) async {
        warmedKeys.append(keys)
    }

    // MARK: - Convenience for tests

    public func resetHistory() {
        coverCalls.removeAll()
        thumbnailCalls.removeAll()
        playerCoverCalls.removeAll()
        setKeys.removeAll()
        removedKeys.removeAll()
        warmedKeys.removeAll()
        clearAllCount = 0
        evictDecodedCount = 0
    }
}
