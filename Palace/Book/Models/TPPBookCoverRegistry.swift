import Foundation
import UIKit
import ImageIO
import PalaceLogging
import PalaceNetwork
import PalaceBookModel
import PalaceBookRegistry

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
        /// Copied from the enclosing actor's `failureThreshold` at record
        /// creation so `isTripped` honors the configured threshold instead of
        /// tripping on the very first failure (which blacklisted a whole cover
        /// CDN for the cooldown window after one Wi-Fi↔cellular blip).
        let failureThreshold: Int
        var isTripped: Bool { consecutiveFailures >= failureThreshold }
    }

    private var records: [String: HostRecord] = [:]

    init(cooldownInterval: TimeInterval = 300, failureThreshold: Int = 3) {
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
        var record = records[host] ?? HostRecord(failureThreshold: failureThreshold)
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
    /// `nonisolated let` (no `(unsafe)`) because `ImageCacheType` is now `Sendable`
    /// — an immutable reference to a Sendable type can be read from any isolation
    /// context without the unchecked escape hatch. See #1129 module-3 playbook:
    /// prefer honest isolation over `nonisolated(unsafe)` once the type is Sendable.
    nonisolated let imageCache: ImageCacheType

    static let shared = TPPBookCoverRegistry(imageCache: ImageCache.shared)

    /// URL-keyed cache of raw image bytes from the network. A single source URL
    /// often needs to be decoded at multiple sizes (catalog cell ~150pt, detail
    /// ~280pt, audiobook player ~screen width). Before this cache existed, each
    /// size variant was a separate network round-trip. With it, the first fetch
    /// saves the bytes and later variants re-decode from RAM.
    ///
    /// `NSCache` is thread-safe but not `Sendable`, so this genuinely needs the
    /// `nonisolated(unsafe)` escape hatch — it lets any actor-isolated method
    /// read/write it without extra hops, and the NSCache internal locking makes
    /// that sound.
    nonisolated(unsafe) private let sourceDataCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 40 * 1024 * 1024 // 40MB of source bytes
        cache.name = "TPPBookCoverRegistry.sourceData"
        return cache
    }()

    /// Dedup concurrent callers that want the same URL's bytes. A swimlane
    /// rendering 10 cells at once must only hit the network once per URL.
    private var inProgressDataTasks: [URL: Task<Data?, Never>] = [:]

    /// Semaphore to limit concurrent image fetches and prevent memory pressure
    private let maxConcurrentFetches: Int
    private var activeFetchCount: Int = 0
    private var waitingContinuations: [CheckedContinuation<Void, Never>] = []

    /// Maximum pixel dimension for decoded images (matches ImageCache device-based limits)
    private let maxDecodeDimension: CGFloat

    /// Tracks hosts that are down to skip requests immediately instead of waiting for timeouts
    let hostFailureTracker: HostFailureTracker

    /// Retained so the observer is torn down in `deinit`. A Wi-Fi↔cellular
    /// handoff briefly fails in-flight image requests on the old interface; on
    /// any reachability change we clear the circuit breaker so the covers that a
    /// transient blip tripped are retried on the new interface instead of
    /// staying blacklisted for the full cooldown window.
    // `nonisolated(unsafe)`: the token is written once in `init` and read once in
    // the actor's `nonisolated deinit` to unregister the observer. Swift 6 forbids
    // touching a non-Sendable stored property from a nonisolated deinit, but deinit
    // runs only when no other reference to the actor exists, so this single teardown
    // read races nothing.
    nonisolated(unsafe) private var reachabilityObserverToken: NSObjectProtocol?

    /// Dedicated URLSession with short timeouts for image fetches.
    /// Using URLSession.shared's 60s default timeout is far too slow when a host is down —
    /// a swimlane with 20 books would waste 40 minutes on doomed requests.
    nonisolated static let imageSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10     // 10s to connect/respond (vs 60s default)
        config.timeoutIntervalForResource = 15    // 15s total per image fetch
        config.waitsForConnectivity = false        // Fail immediately if no network
        // 8 matches our concurrent fetch slot budget (maxConcurrentFetches). The old
        // cap of 4 was the real bottleneck: a single-CDN library serving every cover
        // from the same host could only run 4 in parallel no matter how many slots
        // we had free.
        config.httpMaximumConnectionsPerHost = 8
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

        // Reset the host circuit breaker on any reachability change. Capturing
        // only the (Sendable) tracker keeps this `@Sendable` observer closure off
        // `self`, so it is sound to install from the actor's initializer.
        let tracker = hostFailureTracker
        reachabilityObserverToken = NotificationCenter.default.addObserver(
            forName: .TPPReachabilityChanged,
            object: nil,
            queue: nil
        ) { _ in
            Task { await tracker.reset() }
        }
    }

    deinit {
        if let token = reachabilityObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Clears the host circuit breaker (fire-and-forget). Call on an account
    /// switch so a host that tripped under the prior library does not keep
    /// suppressing cover fetches for the newly selected library. `nonisolated`
    /// + a detached reset lets synchronous main-actor callers (the account
    /// switch path) invoke it without `await`; capturing only the Sendable
    /// tracker keeps this off `self`.
    nonisolated func resetHostFailures() {
        let tracker = hostFailureTracker
        Task { await tracker.reset() }
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

    func coverImage(for book: TPPBook, displayHeight: CGFloat? = nil) async -> UIImage? {
        if let url = book.imageURL, let image = await fetchImage(from: url, for: book, isCover: true) {
            return image
        }

        return await thumbnailImage(for: book, displayHeight: displayHeight)
    }

    func thumbnailImage(for book: TPPBook, displayHeight: CGFloat? = nil) async -> UIImage? {
        if let url = book.imageThumbnailURL, let image = await fetchImage(from: url, for: book, isCover: false) {
            return image
        }

        return await placeholder(for: book, displayHeight: displayHeight)
    }

    /// Target decode dimension (in pixels) for a cover shown at `displayPoints`.
    ///
    /// Decodes at EXACTLY the display pixel box (1:1) — NOT oversampled. Handing
    /// SwiftUI a bitmap larger than the box it's drawn into forces Core Animation
    /// to minify a non-mipmapped texture on every frame; as the cell scrolls the
    /// subpixel sample position shifts each frame, which is precisely the
    /// shimmer/aliasing seen on cover edges during scroll. A 1:1 decode makes the
    /// blit exact. Clamped to 1200px to bound memory on very large display sizes.
    ///
    /// Pure + static so the sizing math is unit-testable without a decode.
    static func decodePixels(displayPoints: CGFloat, scale: CGFloat) -> CGFloat {
        min(displayPoints * scale, 1200)
    }

    /// Fetches a cover decoded at the minimum pixel size needed for a given display size.
    /// Pass the view's point height (or width); the method converts to pixels using screen scale
    /// and clamps to a sensible max. Use this instead of `coverImage(for:)` when you know
    /// the display size ahead of time so you don't over- or under-fetch.
    func coverImage(for book: TPPBook, displayPoints: CGFloat) async -> UIImage? {
        // A non-finite / non-positive display size (a view mid-layout) would trap at
        // `Int(neededPixels)` below and in the downstream TenPrint size math. Drop to
        // the unsized cover path instead. PP-4772 / 077218fc.
        guard let displayPoints = displayPoints.finitePositiveDimension else {
            return await coverImage(for: book)
        }
        let scale = await MainActor.run { UIScreen.main.scale }
        let neededPixels = Self.decodePixels(displayPoints: displayPoints, scale: scale)
        let key = "\(book.identifier)_\(Int(neededPixels))px"

        if let cached = await imageCache.getAsync(for: key) { return cached }

        // No network image — fall back directly to a size-aware placeholder so TenPrint
        // renders at the display size rather than the fixed 80×120 thumbnail size.
        //
        // For small display sizes (catalog cells ~150pt) prefer the thumbnail
        // URL: prefetch (CatalogViewModel.prefetchThumbnails → thumbnailImage)
        // fetches `imageThumbnailURL`, and `sourceData(for:)` dedups by URL, so
        // sharing the URL lets the cell fetch coalesce onto the prefetch task
        // instead of pulling the full-res `imageURL` a second time.
        guard let url = Self.coverSourceURL(
            imageURL: book.imageURL,
            thumbnailURL: book.imageThumbnailURL,
            displayPoints: displayPoints
        ) else {
            return await coverImage(for: book, displayHeight: displayPoints)
        }

        guard let data = await sourceData(for: url) else {
            return await coverImage(for: book, displayHeight: displayPoints)
        }

        if let image = Self.downsampleImage(data: data, maxDimension: neededPixels) {
            storeDecoded(image, for: key, identifier: book.identifier)
            return image
        }

        // Decoding at the requested size failed — try a smaller decode against
        // the same bytes instead of re-hitting the network.
        if let fallback = Self.downsampleImage(data: data, maxDimension: maxDecodeDimension) {
            storeDecoded(fallback, for: book.identifier, identifier: book.identifier)
            return fallback
        }

        Log.error(#file, "Failed to decode image data from URL: \(url)")
        TPPErrorLogger.logImageDecodeFail(url: url)
        return await coverImage(for: book, displayHeight: displayPoints)
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
        let key = "\(book.identifier)_player"

        if let cached = await imageCache.getAsync(for: key) {
            return cached
        }

        guard let data = await sourceData(for: url) else {
            return await coverImage(for: book)
        }

        if let image = Self.downsampleImage(data: data, maxDimension: playerDimension) {
            storeDecoded(image, for: key, identifier: book.identifier)
            return image
        }

        if let fallback = Self.downsampleImage(data: data, maxDimension: maxDecodeDimension) {
            storeDecoded(fallback, for: book.identifier, identifier: book.identifier)
            return fallback
        }

        return await coverImage(for: book)
    }

    private func fetchImage(from url: URL, for book: TPPBook, isCover: Bool) async -> UIImage? {
        let key = cacheKey(for: book, isCover: isCover)
        if let img = await imageCache.getAsync(for: key as String) {
            return img
        }

        // Memory pressure backoff: while an LCP PDF is opening, the
        // decrypt walk + Readium page rendering consume large memory
        // buffers; layering background cover prefetches on top is what
        // tipped device opens into OOM (visible in the device log as
        // "Memory warning received" followed by SIGABRT). Skip the
        // network + decode here — callers see the same nil-on-miss
        // they'd see during a transient network failure, and the
        // catalog re-fetches naturally when the user scrolls back.
        #if LCP
        if LCPPDFOpenProgress.isOpenInProgress {
            return nil
        }
        #endif

        guard let data = await sourceData(for: url) else { return nil }

        guard let image = Self.downsampleImage(
            data: data,
            maxDimension: self.maxDecodeDimension
        ) else {
            Log.error(#file, "Failed to decode image data from URL: \(url)")
            TPPErrorLogger.logImageDecodeFail(url: url)
            return nil
        }

        storeDecoded(image, for: key as String, identifier: book.identifier)
        return image
    }

    /// Fetches raw image bytes for a URL, caching by URL. Subsequent callers for
    /// the same URL (regardless of desired decode size) are served from memory.
    /// Concurrent callers coalesce onto a single network task.
    ///
    /// On a host-level failure, trips the circuit breaker so the remaining books
    /// in a lane skip the network entirely.
    private func sourceData(for url: URL) async -> Data? {
        let key = url.absoluteString as NSString
        if let cached = sourceDataCache.object(forKey: key) {
            return cached as Data
        }

        if await hostFailureTracker.isHostFailing(url.host) {
            return nil
        }

        if let existing = inProgressDataTasks[url] {
            return await existing.value
        }

        let task = Task<Data?, Never> { [weak self] in
            guard let self else { return nil }

            await self.acquireFetchSlot()
            defer { Task { await self.releaseFetchSlot() } }

            // Recompute the cache key inside the Task from the Sendable `url`
            // rather than capturing the outer `key` (`NSString`, non-Sendable) —
            // capturing it made this `sending` Task closure trip the
            // `complete`-mode "risks data races between 'self'-isolated code and
            // concurrent execution of the closure" diagnostic. `url` is Sendable
            // and the key is a pure function of it, so this is behavior-identical.
            let key = url.absoluteString as NSString

            do {
                let (data, _) = try await Self.imageSession.data(
                    for: URLRequest.withoutHTTP3Assumption(url: url)
                )
                await self.hostFailureTracker.recordSuccess(for: url.host)
                self.sourceDataCache.setObject(data as NSData, forKey: key, cost: data.count)
                return data
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

        inProgressDataTasks[url] = task
        let data = await task.value
        inProgressDataTasks[url] = nil
        return data
    }

    /// Stores a decoded image under its sized key AND under the bare identifier,
    /// so later fetches at a different size find an immediately-usable placeholder
    /// in the sync memory cache (`TPPBook.fetchCoverImage` hits this before going
    /// async and showing a skeleton).
    ///
    /// The shared identifier slot may be overwritten by a later size, but the
    /// ImageCache normalizes everything to `maxDimension` on write, so the quality
    /// floor is the same regardless of which variant wrote last.
    private func storeDecoded(_ image: UIImage, for key: String, identifier: String) {
        imageCache.set(image, for: key, expiresIn: nil)
        if key != identifier {
            imageCache.set(image, for: identifier, expiresIn: nil)
        }
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
        // A non-finite / non-positive max dimension yields a bogus
        // `kCGImageSourceThumbnailMaxPixelSize` and can propagate into `Int`
        // conversions upstream; treat it as an unusable request. PP-4772.
        guard let maxDimension = maxDimension.finitePositiveDimension else { return nil }
        return autoreleasepool {
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

    private func placeholder(for book: TPPBook, displayHeight: CGFloat? = nil) async -> UIImage? {
        await MainActor.run {
            tenPrintImage(title: book.title, authors: book.authors, displayHeight: displayHeight)
        }
    }

    /// Renders a TenPrint cover at the given display height (or the default 120 pt if nil).
    /// The view scale and aspect ratio are kept proportional to the original 80x120 design.
    /// Must be called on the MainActor.
    @MainActor
    private func tenPrintImage(title: String, authors: String?, displayHeight: CGFloat?) -> UIImage? {
        let baseHeight: CGFloat = 120
        let height = displayHeight ?? baseHeight
        let width = height * (80.0 / baseHeight)       // maintain 2:3 aspect ratio
        let viewScale = 0.4 * (height / baseHeight)    // keep strokes/fonts proportional

        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { ctx in
                if let view = NYPLTenPrintCoverView(
                    frame: CGRect(origin: .zero, size: size),
                    withTitle: title,
                    withAuthor: authors ?? "Unknown Author",
                    withScale: Float(viewScale)
                ) {
                    view.layer.render(in: ctx.cgContext)
                }
            }
    }

    private func cost(for image: UIImage) -> Int {
        Int(image.size.width * image.size.height * 4)
    }

    private func cacheKey(for book: TPPBook, isCover: Bool) -> NSString {
        NSString(string: "\(book.identifier)_\(isCover ? "cover" : "thumbnail")")
    }

    /// The maximum display size (points) treated as "small" — a catalog cell.
    /// Below this we prefer the thumbnail source so the cell fetch shares a
    /// dedup key with prefetch.
    static let smallDisplayThreshold: CGFloat = 200

    /// Selects which source URL to fetch for a cover shown at `displayPoints`.
    ///
    /// Small displays (catalog cells) prefer `thumbnailURL` so the decode shares
    /// a `sourceData(for:)` dedup key with prefetch (which fetches
    /// `imageThumbnailURL`) — one download per book instead of two after a
    /// Wi-Fi↔cellular switch. Larger displays keep the full-resolution
    /// `imageURL`. Falls back to `imageURL` when no thumbnail exists.
    nonisolated static func coverSourceURL(
        imageURL: URL?,
        thumbnailURL: URL?,
        displayPoints: CGFloat
    ) -> URL? {
        if displayPoints <= smallDisplayThreshold, let thumbnailURL {
            return thumbnailURL
        }
        return imageURL
    }

    // MARK: - Safe URL-based Fetching (for bridge to prevent book deallocation crashes)

    /// Fetch image by URL without requiring a book reference.
    /// This prevents EXC_BAD_ACCESS crashes when the book is deallocated during fetch.
    func fetchImageByURL(_ url: URL, identifier: String, isCover: Bool) async -> UIImage? {
        let key = "\(identifier)_\(isCover ? "cover" : "thumbnail")"

        if let img = await imageCache.getAsync(for: key) {
            return img
        }

        guard let data = await sourceData(for: url) else { return nil }

        guard let image = Self.downsampleImage(
            data: data,
            maxDimension: self.maxDecodeDimension
        ) else {
            Log.error(#file, "Failed to decode image data from URL: \(url)")
            TPPErrorLogger.logImageDecodeFail(url: url)
            return nil
        }

        storeDecoded(image, for: key, identifier: identifier)
        return image
    }

    /// Generate a placeholder image without requiring a book reference.
    /// This prevents EXC_BAD_ACCESS crashes when the book is deallocated.
    func generatePlaceholder(title: String, authors: String?, displayHeight: CGFloat? = nil) async -> UIImage? {
        await MainActor.run {
            tenPrintImage(title: title, authors: authors, displayHeight: displayHeight)
        }
    }

}

// MARK: - Objective-C Bridge
//
// `TPPBookCoverRegistryBridge` was removed in the swarm_d5a3d473 Track A
// consolidation (2026-05-19). Its responsibilities moved to the
// `ImageLoading` umbrella's completion-style overloads on `ImageLoader`,
// which is constructed once in `AppContainer.production()` and injected
// through `AppContainer.imageLoader`. Call sites that used to read
// `TPPBookCoverRegistryBridge.shared` now read `imageLoader` either via
// explicit `AppContainer` injection (BookListView, TPPBookRegistry,
// CarPlayImageProvider) or via the `AppContainer.production().imageLoader`
// computed accessor on TPPBook+Presentation.
