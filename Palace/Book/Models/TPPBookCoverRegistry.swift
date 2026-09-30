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
/// Without it, when a library's image host is down every book in a lane waits on
/// DNS timeouts before falling back to a placeholder.
actor HostFailureTracker {

    /// How long to remember a host failure before retrying
    let cooldownInterval: TimeInterval

    /// Number of consecutive failures before tripping the circuit breaker
    let failureThreshold: Int

    private struct HostRecord {
        var consecutiveFailures: Int = 0
        var lastFailureDate: Date = Date()
        /// Copied from the actor's `failureThreshold` so `isTripped` does not
        /// trip on a single failure (e.g. one Wi-Fi↔cellular blip).
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
    /// `nonisolated let` (no `(unsafe)`) because `ImageCacheType` is `Sendable`.
    nonisolated let imageCache: ImageCacheType

    static let shared = TPPBookCoverRegistry(imageCache: ImageCache.shared)

    /// URL-keyed cache of raw image bytes, so one source decoded at several sizes
    /// (cell, detail, player) costs one network round-trip.
    ///
    /// `NSCache` is thread-safe but not `Sendable`; its internal locking makes
    /// `nonisolated(unsafe)` sound here.
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

    /// How long a URL that answered with a non-image is left alone before being
    /// asked again (PP-4968).
    ///
    /// The refusal below already stops bad bytes being cached, so the cover
    /// recovers when the host does. What it does not do is stop us ASKING: a
    /// URL that reliably answers 403 or 404 was re-requested on every
    /// appearance, which in September 2026 meant 97,320 decode-failure reports
    /// across 6,604 patrons — 14.7 each — plus a round trip apiece. The two
    /// live shapes are both persistent rather than transient: BiblioBoard
    /// 302-redirects covers to a signed CloudFront URL that denies the request,
    /// and answers 404 for audiobook items that have no thumbnail at all.
    ///
    /// Bounded rather than permanent, because `HostFailureTracker` cannot cover
    /// this case — a 403/404 is a SUCCESSFUL HTTP transaction, so it never
    /// throws and never reaches the `catch` that records host failures. A
    /// permanent memo would reintroduce the defect #1405 fixed, where a cover
    /// that was briefly unavailable never returned for the process lifetime.
    /// One minute is long enough that scrolling a shelf back and forth costs one
    /// request rather than one per appearance, and short enough that a patron
    /// who waits out a transient outage sees the cover without relaunching.
    static let badResponseRetryInterval: TimeInterval = 60

    /// Ceiling on the backoff below. Bounded rather than permanent so a cover
    /// added to the catalogue later is still discovered within a session.
    static let maxBadResponseRetryInterval: TimeInterval = 1800

    /// URLs whose last response could not be an image: when it was last seen,
    /// and how many consecutive times.
    ///
    /// Keyed by URL, never by host — one dead thumbnail must not blank the
    /// shelf around it.
    ///
    /// The strike count exists because the measured population is not
    /// transient. Of the 12 distinct BiblioBoard cover URLs sampled from
    /// September 2026's decode failures, all 12 still fail reproducibly — 6
    /// with 403 (its signed CloudFront redirect denies the request) and 6 with
    /// 404 ("unable to map thumbnail request … type=AUDIOBOOK"). A flat
    /// interval would re-request every one of them once per interval for the
    /// life of the process. Doubling per consecutive failure keeps a genuinely
    /// transient outage recovering quickly while a URL that is simply not
    /// served backs off toward the cap.
    private struct BadResponse {
        var seenAt: Date
        var strikes: Int
    }
    private var badResponses: [URL: BadResponse] = [:]

    /// Injected so a test can cross `badResponseRetryInterval` without sleeping.
    private let now: @Sendable () -> Date

    /// Reachability observer: a Wi-Fi↔cellular handoff briefly fails in-flight
    /// requests, so any reachability change clears the circuit breaker.
    // `nonisolated(unsafe)`: written once in `init`, read once in the nonisolated
    // `deinit`, when no other reference to the actor exists.
    nonisolated(unsafe) private var reachabilityObserverToken: NSObjectProtocol?

    /// Dedicated URLSession with short timeouts for image fetches.
    /// Using URLSession.shared's 60s default timeout is far too slow when a host is down —
    /// a swimlane with 20 books would waste 40 minutes on doomed requests.
    nonisolated static let imageSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10     // 10s to connect/respond (vs 60s default)
        config.timeoutIntervalForResource = 15    // 15s total per image fetch
        config.waitsForConnectivity = false        // Fail immediately if no network
        // Matches maxConcurrentFetches; single-CDN libraries serve every cover
        // from one host.
        config.httpMaximumConnectionsPerHost = 8
        config.urlCache = nil                      // Images have their own cache layer
        return URLSession(configuration: config)
    }()

    /// The session image fetches actually run on.
    ///
    /// Injected so `sourceData(for:)` is testable: a globally registered
    /// `URLProtocol` cannot reach a session built from its own configuration.
    ///
    /// `nonisolated let`: written once in `init`, `URLSession` is `Sendable`,
    /// and the fetch reads it from a detached `Task`.
    nonisolated let urlSession: URLSession

    init(
        imageCache: ImageCacheType,
        hostFailureTracker: HostFailureTracker = HostFailureTracker(),
        urlSession: URLSession = TPPBookCoverRegistry.imageSession,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.imageCache = imageCache
        self.hostFailureTracker = hostFailureTracker
        self.urlSession = urlSession
        self.now = now

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
    /// switch so a host tripped under the prior library does not suppress covers
    /// for the new one. `nonisolated` so synchronous callers need no `await`.
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
    /// Decodes at exactly the display pixel box (1:1), not oversampled: a larger
    /// bitmap makes Core Animation minify a non-mipmapped texture each frame,
    /// which shimmers on cover edges during scroll. Clamped to 1200px.
    static func decodePixels(displayPoints: CGFloat, scale: CGFloat) -> CGFloat {
        min(displayPoints * scale, 1200)
    }

    /// Cache key for a cover decoded at `pixels` (from `decodePixels`). Shared
    /// with `ImageLoader`'s cache short-circuit so both look up the same entry.
    static func sizedCoverKey(identifier: String, pixels: CGFloat) -> String {
        "\(identifier)_\(Int(pixels))px"
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
        let key = Self.sizedCoverKey(identifier: book.identifier, pixels: neededPixels)

        if let cached = await imageCache.getAsync(for: key) { return cached }

        // No network image: fall back to a size-aware TenPrint placeholder.
        // Small displays use the thumbnail URL so the fetch coalesces with
        // prefetch (see `coverSourceURL`).
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

        // Memory-pressure backoff: while an LCP PDF is opening, cover prefetches
        // on top of decryption and page rendering can push the device into OOM.
        // Callers see the same nil as a transient network failure.
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
    /// True while `url`'s last non-image response is still inside
    /// `badResponseRetryInterval`. Expired entries are dropped on read, so the
    /// table cannot grow without bound across a long browsing session.
    /// `base * 2^(strikes-1)`, capped. One strike gives the base interval.
    private static func retryInterval(forStrikes strikes: Int) -> TimeInterval {
        let exponent = max(0, strikes - 1)
        // Clamp the shift before it is applied; `pow` on a large exponent
        // overflows to infinity and would make the backoff permanent.
        guard exponent < 32 else { return maxBadResponseRetryInterval }
        let widened = badResponseRetryInterval * TimeInterval(1 << exponent)
        return min(widened, maxBadResponseRetryInterval)
    }

    /// True while this URL's last non-image response is still inside its
    /// current backoff window. An expired record is kept, not dropped — its
    /// strike count is what widens the next window — but it no longer
    /// suppresses, so the URL is asked again.
    private func isWithinBadResponseInterval(_ url: URL) -> Bool {
        guard let record = badResponses[url] else { return false }
        let window = Self.retryInterval(forStrikes: record.strikes)
        return now().timeIntervalSince(record.seenAt) < window
    }

    private func noteBadResponse(for url: URL) {
        let strikes = (badResponses[url]?.strikes ?? 0) + 1
        badResponses[url] = BadResponse(seenAt: now(), strikes: strikes)
    }

    /// Cleared entirely on a usable response, so a cover that comes back is
    /// neither held out for the remainder of its window nor carries its old
    /// strikes into some later, unrelated failure.
    ///
    /// Not directly covered by a test, and the reason is a seam rather than an
    /// oversight: a successful fetch also stores the bytes in `sourceDataCache`,
    /// so every later request for that URL is served from cache and never
    /// reaches this path again. The reset only becomes observable once NSCache
    /// evicts under memory pressure, which a unit test cannot force. A test
    /// scripting a later failure would measure the positive cache and pass with
    /// this line deleted — see the note on
    /// `testRecoveryAfterTwoStrikes_isNotSuppressedByTheWidenedWindow`.
    private func clearBadResponse(for url: URL) {
        badResponses[url] = nil
    }

    private func sourceData(for url: URL) async -> Data? {
        let key = url.absoluteString as NSString
        if let cached = sourceDataCache.object(forKey: key) {
            return cached as Data
        }

        if await hostFailureTracker.isHostFailing(url.host) {
            return nil
        }

        // PP-4968: this URL answered with something that cannot be an image
        // recently enough that asking again is not worth a round trip. Checked
        // AFTER the positive cache, so a URL that has since been fetched
        // successfully is served from cache rather than suppressed, and BEFORE
        // the in-progress table, so a shelf rendering ten cells at once does not
        // queue ten doomed requests behind one another.
        if isWithinBadResponseInterval(url) {
            return nil
        }

        if let existing = inProgressDataTasks[url] {
            return await existing.value
        }

        let task = Task<Data?, Never> { [weak self] in
            guard let self else { return nil }

            await self.acquireFetchSlot()
            defer { Task { await self.releaseFetchSlot() } }

            // Recomputed from the Sendable `url` rather than capturing the outer
            // non-Sendable `NSString` key into the `sending` Task closure.
            let key = url.absoluteString as NSString

            do {
                let (data, response) = try await self.urlSession.data(
                    for: URLRequest.withoutHTTP3Assumption(url: url)
                )
                // Refuse non-2xx and empty bodies so they are not cached: cached
                // bad bytes would pin the TenPrint placeholder for the process
                // lifetime (this session has no URLCache underneath). A truncated
                // JPEG still decodes; zero bytes is the input that does not.
                // The refusal is logged here because the decode-side
                // `logImageDecodeFail` no longer sees these responses.
                let status = (response as? HTTPURLResponse)?.statusCode
                let statusIsUsable = status.map { (200..<300).contains($0) } ?? true
                guard statusIsUsable, !data.isEmpty else {
                    Log.error(#file, "Unusable image response from \(url) — status \(status.map(String.init) ?? "none"), \(data.count) bytes; not cached")
                    TPPErrorLogger.logImageDecodeFail(url: url)
                    // Remember the refusal, not the bytes (PP-4968). Without
                    // this the next appearance of the same dead cover repeats
                    // the whole exchange, which is what made one unusable cover
                    // cost 14.7 reports per affected patron.
                    await self.noteBadResponse(for: url)
                    return nil
                }
                await self.clearBadResponse(for: url)
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
// Completion-style access goes through `ImageLoader` (`AppContainer.imageLoader`).
