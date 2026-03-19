import Foundation
import UIKit
import ImageIO

// MARK: - Host Failure Tracker (Circuit Breaker)

/// Tracks hosts that are consistently failing (e.g., DNS resolution errors) and allows
/// callers to skip requests to those hosts immediately instead of waiting for timeouts.
///
/// This is critical for performance when a library's image host is down — without it,
/// each book in a swimlane wastes 2 sequential network requests waiting for DNS timeouts
/// before falling back to a placeholder. With it, the first failure trips the circuit
/// and all subsequent requests skip instantly.
actor HostFailureTracker {

    /// How long to remember a host failure before retrying
    let cooldownInterval: TimeInterval

    /// Number of consecutive failures before tripping the circuit breaker
    let failureThreshold: Int

    private struct HostRecord {
        var consecutiveFailures: Int = 0
        var lastFailureDate: Date = Date()
        var isTripped: Bool { consecutiveFailures >= 1 }
    }

    private var records: [String: HostRecord] = [:]

    init(cooldownInterval: TimeInterval = 300, failureThreshold: Int = 1) {
        self.cooldownInterval = cooldownInterval
        self.failureThreshold = failureThreshold
    }

    /// Returns true if the host is known to be failing and should be skipped
    func isHostFailing(_ host: String?) -> Bool {
        guard let host, let record = records[host] else { return false }

        // If enough time has passed, allow a retry
        if Date().timeIntervalSince(record.lastFailureDate) > cooldownInterval {
            records.removeValue(forKey: host)
            return false
        }

        return record.isTripped
    }

    /// Records a failure for a host. After `failureThreshold` consecutive failures,
    /// the host is marked as failing and requests to it will be skipped.
    func recordFailure(for host: String?) {
        guard let host else { return }
        var record = records[host] ?? HostRecord()
        record.consecutiveFailures += 1
        record.lastFailureDate = Date()
        records[host] = record
    }

    /// Records a success, resetting the failure counter for this host.
    func recordSuccess(for host: String?) {
        guard let host else { return }
        records.removeValue(forKey: host)
    }

    /// Clears all tracked failures (e.g., on account change or app foregrounding)
    func reset() {
        records.removeAll()
    }
}

// MARK: - Swift Concurrency Actor
actor TPPBookCoverRegistry {
    let imageCache: ImageCacheType

    static let shared = TPPBookCoverRegistry(imageCache: ImageCache.shared)

    private var inProgressTasks: [URL: Task<UIImage?, Never>] = [:]

    /// Semaphore to limit concurrent image fetches and prevent memory pressure
    private let maxConcurrentFetches: Int
    private var activeFetchCount: Int = 0
    private var waitingContinuations: [CheckedContinuation<Void, Never>] = []

    /// Maximum pixel dimension for decoded images (matches ImageCache device-based limits)
    private let maxDecodeDimension: CGFloat

    /// Tracks hosts that are down to skip requests immediately instead of waiting for timeouts
    let hostFailureTracker: HostFailureTracker

    /// Dedicated URLSession with short timeouts for image fetches.
    /// Using URLSession.shared's 60s default timeout is far too slow when a host is down —
    /// a swimlane with 20 books would waste 40 minutes on doomed requests.
    nonisolated static let imageSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10     // 10s to connect/respond (vs 60s default)
        config.timeoutIntervalForResource = 15    // 15s total per image fetch
        config.waitsForConnectivity = false        // Fail immediately if no network
        config.httpMaximumConnectionsPerHost = 4   // Limit per-host connections
        config.urlCache = nil                      // Images have their own cache layer
        return URLSession(configuration: config)
    }()

    init(
        imageCache: ImageCacheType,
        hostFailureTracker: HostFailureTracker = HostFailureTracker()
    ) {
        self.imageCache = imageCache
        self.hostFailureTracker = hostFailureTracker

        let deviceMemoryMB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)
        if deviceMemoryMB < 2048 {
            maxConcurrentFetches = 3
            maxDecodeDimension = 512
        } else if deviceMemoryMB < 4096 {
            maxConcurrentFetches = 5
            maxDecodeDimension = 768
        } else {
            maxConcurrentFetches = 8
            maxDecodeDimension = 1024
        }
    }

    // MARK: - Concurrency Throttling

    /// Waits until a fetch slot is available (limits concurrent image downloads)
    private func acquireFetchSlot() async {
        if activeFetchCount < maxConcurrentFetches {
            activeFetchCount += 1
            return
        }

        await withCheckedContinuation { continuation in
            waitingContinuations.append(continuation)
        }
    }

    /// Releases a fetch slot and wakes up a waiting task if any
    private func releaseFetchSlot() {
        if !waitingContinuations.isEmpty {
            let next = waitingContinuations.removeFirst()
            next.resume()
        } else {
            activeFetchCount -= 1
        }
    }

    // MARK: - Public API

    func coverImage(for book: TPPBook) async -> UIImage? {
        if let url = book.imageURL, let image = await fetchImage(from: url, for: book, isCover: true) {
            return image
        }

        return await thumbnailImage(for: book)
    }

    func thumbnailImage(for book: TPPBook) async -> UIImage? {
        if let url = book.imageThumbnailURL, let image = await fetchImage(from: url, for: book, isCover: false) {
            return image
        }

        return await placeholder(for: book)
    }

    /// Fetches a cover decoded at the minimum pixel size needed for a given display size.
    /// Pass the view's point height (or width); the method converts to pixels using screen scale
    /// and clamps to a sensible max. Use this instead of `coverImage(for:)` when you know
    /// the display size ahead of time so you don't over- or under-fetch.
    func coverImage(for book: TPPBook, displayPoints: CGFloat) async -> UIImage? {
        let scale = await MainActor.run { UIScreen.main.scale }
        let neededPixels = min(displayPoints * scale * 1.5, 1200) // 1.5× for sharp rendering
        let key = "\(book.identifier)_\(Int(neededPixels))px" as NSString

        if let cached = imageCache.get(for: key as String) { return cached }

        guard let url = book.imageURL else { return await coverImage(for: book) }
        if await hostFailureTracker.isHostFailing(url.host) { return await coverImage(for: book) }

        await acquireFetchSlot()
        defer { Task { await self.releaseFetchSlot() } }

        do {
            let (data, _) = try await Self.imageSession.data(from: url)
            await hostFailureTracker.recordSuccess(for: url.host)
            guard let image = Self.downsampleImage(data: data, maxDimension: neededPixels) else {
                return await coverImage(for: book)
            }
            imageCache.set(image, for: key as String, expiresIn: nil)
            return image
        } catch {
            return await coverImage(for: book)
        }
    }

    /// Fetches a full-resolution cover for the audiobook player, where the image
    /// is displayed at full screen width. Uses the actual screen pixel width as the
    /// decode limit, bypassing the conservative per-device memory caps used elsewhere.
    func playerCoverImage(for book: TPPBook) async -> UIImage? {
        guard let url = book.imageURL else {
            return await coverImage(for: book)
        }

        let screenPixelWidth = await MainActor.run {
            UIScreen.main.bounds.width * UIScreen.main.scale
        }
        let playerDimension = min(screenPixelWidth, 1200)
        let key = "\(book.identifier)_player" as NSString

        if let cached = imageCache.get(for: key as String) {
            return cached
        }

        if await hostFailureTracker.isHostFailing(url.host) {
            return await coverImage(for: book)
        }

        await acquireFetchSlot()
        defer { Task { await self.releaseFetchSlot() } }

        do {
            let (data, _) = try await Self.imageSession.data(from: url)
            await hostFailureTracker.recordSuccess(for: url.host)

            guard let image = Self.downsampleImage(data: data, maxDimension: playerDimension) else {
                return await coverImage(for: book)
            }

            imageCache.set(image, for: key as String, expiresIn: nil)
            return image
        } catch {
            return await coverImage(for: book)
        }
    }

    private func fetchImage(from url: URL, for book: TPPBook, isCover: Bool) async -> UIImage? {
        let key = cacheKey(for: book, isCover: isCover)
        if let img = imageCache.get(for: key as String) {
            return img
        }

        // Circuit breaker: skip immediately if this host is known to be failing
        if await hostFailureTracker.isHostFailing(url.host) {
            return nil
        }

        if let existing = inProgressTasks[url] {
            return await existing.value
        }

        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }

            await self.acquireFetchSlot()
            defer { Task { await self.releaseFetchSlot() } }

            do {
                let (data, _) = try await Self.imageSession.data(from: url)

                // Host is reachable — clear any failure record
                await self.hostFailureTracker.recordSuccess(for: url.host)

                guard let image = Self.downsampleImage(
                    data: data,
                    maxDimension: self.maxDecodeDimension
                ) else {
                    Log.error(#file, "Failed to decode image data from URL: \(url)")
                    TPPErrorLogger.logImageDecodeFail(url: url)
                    return nil
                }

                self.imageCache.set(image, for: key as String, expiresIn: nil)
                return image
            } catch {
                if Self.isHostLevelError(error) {
                    await self.hostFailureTracker.recordFailure(for: url.host)
                    Log.warn(#file, "Host failure recorded for \(url.host ?? "unknown"): \(error.localizedDescription)")
                    if let host = url.host {
                        TPPErrorLogger.logImageHostFailure(host: host, error: error, url: url)
                    }
                }

                Log.error(#file, "Failed to fetch image from \(url): \(error.localizedDescription)")
                return nil
            }
        }

        inProgressTasks[url] = task
        let image = await task.value

        inProgressTasks[url] = nil

        return image
    }

    /// Determines if an error indicates a host-level failure (DNS, connection, etc.)
    /// vs a transient or request-specific error (timeout on a slow response, etc.)
    private nonisolated static func isHostLevelError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }

        switch nsError.code {
        case NSURLErrorCannotFindHost,       // DNS resolution failed
             NSURLErrorDNSLookupFailed,       // DNS lookup failed
             NSURLErrorCannotConnectToHost,   // Host reachable but refusing connections
             NSURLErrorSecureConnectionFailed: // SSL/TLS failure (cert issues)
            return true
        default:
            return false
        }
    }

    // MARK: - CGImageSource-based Downsampled Decoding

    /// Decodes image data directly at the target size using CGImageSource.
    ///
    /// This avoids two critical problems:
    /// 1. **iOS 26 JPEG color space bug** (rdar://143602439) where `UIImage(data:)` +
    ///    `byPreparingForDisplay()` fails on 24-bpp JFIF images with `kCGImageBlockFormatBGRx8`
    ///    errors, producing corrupt images that leak memory.
    /// 2. **Peak memory pressure** from decoding full-resolution images before resizing.
    ///    CGImageSource decodes directly at the target size, so a 3000x4000 cover image
    ///    never exists uncompressed in memory.
    ///
    /// - Parameters:
    ///   - data: Raw image data (JPEG, PNG, etc.)
    ///   - maxDimension: Maximum width or height for the decoded image
    /// - Returns: A decoded UIImage at the target size, or nil if decoding fails
    nonisolated static func downsampleImage(data: Data, maxDimension: CGFloat) -> UIImage? {
        autoreleasepool {
            let options: [CFString: Any] = [
                kCGImageSourceShouldCache: false  // Don't cache the full-size image
            ]

            guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
                return nil
            }

            let downsampleOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                kCGImageSourceCreateThumbnailWithTransform: true,  // Respect EXIF orientation
                kCGImageSourceShouldCacheImmediately: true  // Decode immediately at target size
            ]

            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                downsampleOptions as CFDictionary
            ) else {
                return nil
            }

            return UIImage(cgImage: cgImage)
        }
    }

    private func placeholder(for book: TPPBook) async -> UIImage? {
        await MainActor.run {
            let size = CGSize(width: 80, height: 120)
            let format = UIGraphicsImageRendererFormat()
            format.scale = UIScreen.main.scale
            return UIGraphicsImageRenderer(size: size, format: format)
                .image { ctx in
                    if let view = NYPLTenPrintCoverView(
                        frame: CGRect(origin: .zero, size: size),
                        withTitle: book.title,
                        withAuthor: book.authors ?? "Unknown Author",
                        withScale: 0.4
                    ) {
                        view.layer.render(in: ctx.cgContext)
                    }
                }
        }
    }

    private func cost(for image: UIImage) -> Int {
        Int(image.size.width * image.size.height * 4)
    }

    private func cacheKey(for book: TPPBook, isCover: Bool) -> NSString {
        NSString(string: "\(book.identifier)_\(isCover ? "cover" : "thumbnail")")
    }

    // MARK: - Safe URL-based Fetching (for bridge to prevent book deallocation crashes)

    /// Fetch image by URL without requiring a book reference.
    /// This prevents EXC_BAD_ACCESS crashes when the book is deallocated during fetch.
    func fetchImageByURL(_ url: URL, identifier: String, isCover: Bool) async -> UIImage? {
        let key = "\(identifier)_\(isCover ? "cover" : "thumbnail")"

        // Check cache first
        if let img = imageCache.get(for: key) {
            return img
        }

        // Circuit breaker: skip immediately if this host is known to be failing
        if await hostFailureTracker.isHostFailing(url.host) {
            return nil
        }

        // Check for existing in-progress task
        if let existing = inProgressTasks[url] {
            return await existing.value
        }

        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }

            await self.acquireFetchSlot()
            defer { Task { await self.releaseFetchSlot() } }

            do {
                let (data, _) = try await Self.imageSession.data(from: url)

                // Host is reachable — clear any failure record
                await self.hostFailureTracker.recordSuccess(for: url.host)

                guard let image = Self.downsampleImage(
                    data: data,
                    maxDimension: self.maxDecodeDimension
                ) else {
                    Log.error(#file, "Failed to decode image data from URL: \(url)")
                    TPPErrorLogger.logImageDecodeFail(url: url)
                    return nil
                }

                self.imageCache.set(image, for: key, expiresIn: nil)
                return image
            } catch {
                if Self.isHostLevelError(error) {
                    await self.hostFailureTracker.recordFailure(for: url.host)
                    Log.warn(#file, "Host failure recorded for \(url.host ?? "unknown"): \(error.localizedDescription)")
                    if let host = url.host {
                        TPPErrorLogger.logImageHostFailure(host: host, error: error, url: url)
                    }
                }

                Log.error(#file, "Failed to fetch image from \(url): \(error.localizedDescription)")
                return nil
            }
        }

        inProgressTasks[url] = task
        let image = await task.value
        inProgressTasks[url] = nil

        return image
    }

    /// Generate a placeholder image without requiring a book reference.
    /// This prevents EXC_BAD_ACCESS crashes when the book is deallocated.
    func generatePlaceholder(title: String, authors: String?) async -> UIImage? {
        await MainActor.run {
            let size = CGSize(width: 80, height: 120)
            let format = UIGraphicsImageRendererFormat()
            format.scale = UIScreen.main.scale
            return UIGraphicsImageRenderer(size: size, format: format)
                .image { ctx in
                    if let view = NYPLTenPrintCoverView(
                        frame: CGRect(origin: .zero, size: size),
                        withTitle: title,
                        withAuthor: authors ?? "Unknown Author",
                        withScale: 0.4
                    ) {
                        view.layer.render(in: ctx.cgContext)
                    }
                }
        }
    }
}

// MARK: - Objective-C Bridge
@objcMembers
public class TPPBookCoverRegistryBridge: NSObject {
    public static let shared = TPPBookCoverRegistryBridge()

    /// Shared image cache reference for safe access
    private let sharedImageCache = ImageCache.shared

    /// Asynchronous, Objective-C friendly cover fetch
    /// - Parameters:
    ///   - book: The TPPBook instance
    ///   - completion: Block called on main thread with the UIImage or nil
    /// - Note: Uses weak reference to book to prevent crashes if book is deallocated during fetch
    public func coverImageForBook(_ book: TPPBook, completion: @escaping (UIImage?) -> Void) {
        // Capture all needed data early to avoid accessing potentially deallocated book later
        let bookIdentifier = book.identifier
        let imageURL = book.imageURL
        let thumbnailURL = book.imageThumbnailURL
        let title = book.title
        let authors = book.authors

        Task { [weak book, sharedImageCache] in
            // Fetch using captured URLs instead of book reference
            var img: UIImage?

            if let url = imageURL {
                img = await TPPBookCoverRegistry.shared.fetchImageByURL(url, identifier: bookIdentifier, isCover: true)
            }

            // Fall back to thumbnail if cover fetch fails
            if img == nil, let url = thumbnailURL {
                img = await TPPBookCoverRegistry.shared.fetchImageByURL(url, identifier: bookIdentifier, isCover: false)
            }

            // Fall back to placeholder if all fetches fail
            if img == nil {
                img = await TPPBookCoverRegistry.shared.generatePlaceholder(title: title, authors: authors)
            }

            // Use main actor for UI-related cache operations
            await MainActor.run {
                if let img = img {
                    // Use shared cache directly instead of book.imageCache to prevent EXC_BAD_ACCESS
                    sharedImageCache.set(img, for: bookIdentifier)
                    // Only update book's cache if book is still alive
                    book?.imageCache.set(img, for: bookIdentifier)
                }
                completion(img)
            }
        }
    }

    /// Asynchronous, Objective-C friendly thumbnail fetch
    /// - Note: Uses weak reference to book to prevent crashes if book is deallocated during fetch
    public func thumbnailImageForBook(_ book: TPPBook, completion: @escaping (UIImage?) -> Void) {
        // Capture all needed data early to avoid accessing potentially deallocated book later
        let bookIdentifier = book.identifier
        let thumbnailURL = book.imageThumbnailURL
        let title = book.title
        let authors = book.authors

        Task { [weak book, sharedImageCache] in
            // Fetch using captured URLs instead of book reference
            var img: UIImage?

            if let url = thumbnailURL {
                img = await TPPBookCoverRegistry.shared.fetchImageByURL(url, identifier: bookIdentifier, isCover: false)
            }

            // Fall back to placeholder if fetch fails
            if img == nil {
                img = await TPPBookCoverRegistry.shared.generatePlaceholder(title: title, authors: authors)
            }

            // Use main actor for UI-related cache operations
            await MainActor.run {
                if let img = img {
                    // Use shared cache directly instead of book.imageCache to prevent EXC_BAD_ACCESS
                    sharedImageCache.set(img, for: bookIdentifier)
                    // Only update book's cache if book is still alive
                    book?.imageCache.set(img, for: bookIdentifier)
                }
                completion(img)
            }
        }
    }
}
