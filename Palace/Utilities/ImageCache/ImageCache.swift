import UIKit
import PalaceLogging
import PalaceBookModel

/// Thread-safe one-shot resumer for `ImageCache.getAsync`'s checked
/// continuation. The continuation must resume exactly once whether the
/// processing operation runs to completion or is cancelled before its block
/// executes (see `getAsync` for the full rationale / Crashlytics breadcrumb).
///
/// `@unchecked Sendable` invariant: the only mutable stored state is
/// `hasResumed`, and every access to it is guarded by `lock`. `continuation`
/// is immutable after init and `CheckedContinuation` is itself `Sendable`.
private final class OneShotImageResumer: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false
    private let continuation: CheckedContinuation<UIImage?, Never>

    init(_ continuation: CheckedContinuation<UIImage?, Never>) {
        self.continuation = continuation
    }

    func resume(_ image: UIImage?) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return }
        hasResumed = true
        continuation.resume(returning: image)
    }
}

/// A queued disk-to-memory decode. A memory warning cancels these and leaves
/// queued writes running, so a cover handed to the cache is not lost.
private final class ImageDecodeOperation: BlockOperation, @unchecked Sendable {}

/// `@unchecked Sendable` invariant: every stored property is either an
/// immutable `let` (`defaultTTL`, `maxDimension`, `compressionQuality`) or a
/// reference to a type that is itself internally thread-safe — `CountedCache`
/// (`memoryImages`) and `OperationQueue` (`processingQueue`) are documented
/// thread-safe by Apple, and `dataCache` (`GeneralCache`) serializes its own
/// access. There is no unguarded mutable stored state on `ImageCache` itself,
/// so concurrent access across the `processingQueue` operations is safe.
///
/// ## Off-main closures are hoisted into explicitly-typed `let`s (load-bearing)
///
/// Every `processingQueue.addOperation` / `BlockOperation.addExecutionBlock` /
/// `completionBlock` closure in this file is bound to an explicitly-typed
/// `let work: @Sendable () -> Void` before being handed to the API, rather than
/// written inline as a trailing-closure literal. This is a WORKAROUND for a
/// confirmed Xcode 26.2 / Swift 6.2 ClangImporter bug (#1338), NOT a style
/// choice — do not "simplify" it back to trailing closures.
///
/// The bug: WebKit's headers annotate blocks with `NS_SWIFT_UI_ACTOR`
/// (`@MainActor`) while Foundation's `-addOperationWithBlock:` /
/// `-addExecutionBlock:` / `completionBlock` use `NS_SWIFT_SENDABLE`. Both are
/// `swift_attr` sugar over the SAME canonical clang block type `void (^)(void)`.
/// The FIRST time any WebKit block declaration is type-checked in a given
/// `swift-frontend` process, the ClangImporter caches the imported Swift type
/// for that canonical block type as `@MainActor @Sendable () -> Void`; every
/// LATER structurally-identical block parameter in the same process (batch or
/// WMO) then surfaces as `@MainActor`. A `@MainActor`-typed closure literal at
/// an `addOperation` call gets a `dispatch_assert_queue(main)` prologue and
/// SIGTRAPs (`swift_task_checkIsolated` → `dispatch_assert_queue_fail`) the
/// instant `processingQueue` runs it off-main — the #1338 bootstrap crash.
/// Which files are affected depends only on frontend batch membership (which is
/// why an unrelated file-set change flipped THIS file), and it is a Palace-
/// independent 2-file reproducer; `import WebKit` alone is not enough, a WebKit
/// declaration must be USED somewhere in the same process.
///
/// Hoisting works because the closure's type comes from the `let` ANNOTATION
/// (`@Sendable () -> Void`, correct), not from the poisonable imported parameter
/// type; passing that typed value to even a poisoned parameter is a safe
/// conversion with no runtime isolation assertion. `nonisolated` on the methods/
/// helpers is retained but is neither necessary nor sufficient for this bug.
/// `handleMemoryWarning`'s `DispatchQueue.main.asyncAfter` closure stays
/// `@MainActor` — correctly, it runs on main.
///
/// If you add a new off-main `NSOperation`-family closure here, hoist it into an
/// explicitly-typed `let` the same way. (Upstream Swift/Apple bug report drafted;
/// remove this workaround once the toolchain is fixed.)
public nonisolated final class ImageCache: ImageCacheType, @unchecked Sendable {
    public static let shared = ImageCache()

    private let dataCache: GeneralCache<String, Data>
    private let memoryImages: CountedCache<String, UIImage>
    private let defaultTTL: TimeInterval = 14 * 24 * 60 * 60
    private let limits: Limits
    private var maxDimension: CGFloat { limits.maxDimension }
    private let compressionQuality: CGFloat = 0.85
    /// JPEG encoder. Injected only by tests, to count encodes.
    private let encode: @Sendable (UIImage, CGFloat) -> Data?
    // Internal (not private) so tests can deterministically exercise the
    // cancellation path of `getAsync` (suspend → enqueue → cancelAllOperations
    // → resume) without spamming a global memory-warning notification through
    // the whole app. Not part of the public API.
    let processingQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .utility
        queue.name = "org.thepalaceproject.imageprocessing"
        return queue
    }()

    /// Per-device-tier cache sizing.
    struct Limits: Equatable {
        let memoryCostLimitMB: Int
        let countLimit: Int
        let maxDimension: CGFloat
        let maxConcurrentProcessing: Int
    }

    /// `maxDimension` caps every stored image. Book detail needs about 840 px
    /// and the audiobook player about 1200 px on a 3x phone, so only devices
    /// with memory to spare get those sizes. `memoryCostLimitMB` is what bounds
    /// the cache: larger images mean fewer cached covers, not more memory.
    /// Memory is reclaimed on library switch via evictAllDecodedImages().
    static func limits(forDeviceMemoryMB deviceMemoryMB: UInt64) -> Limits {
        if deviceMemoryMB < 2048 {
            return Limits(memoryCostLimitMB: 15, countLimit: 60, maxDimension: 200, maxConcurrentProcessing: 2)
        } else if deviceMemoryMB < 4096 {
            return Limits(memoryCostLimitMB: 25, countLimit: 100, maxDimension: 600, maxConcurrentProcessing: 3)
        } else {
            return Limits(memoryCostLimitMB: 40, countLimit: 150, maxDimension: 1200, maxConcurrentProcessing: 4)
        }
    }

    private convenience init() {
        self.init(
            deviceMemoryMB: ProcessInfo.processInfo.physicalMemory / (1024 * 1024),
            decodedImageBytes: AppCacheCounters.decodedImages,
            compressedDataBytes: AppCacheCounters.imageData
        )
    }

    private init(
        deviceMemoryMB: UInt64,
        cacheName: String = "ImageCache",
        encode: @escaping @Sendable (UIImage, CGFloat) -> Data? = { $0.jpegData(compressionQuality: $1) },
        decodedImageBytes: CacheByteCounter = CacheByteCounter(),
        compressedDataBytes: CacheByteCounter = CacheByteCounter(),
        memoryRelease: MemoryReleaseCoordinator = .shared
    ) {
        memoryImages = CountedCache(counter: decodedImageBytes)
        // Compressed data stays on disk only (PP-5583): `memoryImages` already
        // holds the decoded copy, and a disk read is what a miss costs anyway.
        dataCache = GeneralCache<String, Data>(
            cacheName: cacheName,
            mode: .diskOnly,
            writeData: { try $0.write(to: $1) },
            byteCounter: compressedDataBytes,
            memoryRelease: memoryRelease
        )
        self.encode = encode
        limits = Self.limits(forDeviceMemoryMB: deviceMemoryMB)
        memoryImages.countLimit = limits.countLimit
        processingQueue.maxConcurrentOperationCount = limits.maxConcurrentProcessing
        memoryImages.totalCostLimit = limits.memoryCostLimitMB * 1024 * 1024

        memoryRelease.register(self, stage: .decodedImages) { cache in
            cache.handleMemoryWarning()
        }
    }

    /// Drops queued decodes and decoded images, and slows the queue to one
    /// operation for 60 s. Queued writes still run: cancelling them would make
    /// the next sync fetch and encode those covers again.
    func handleMemoryWarning() {
        for operation in processingQueue.operations where operation is ImageDecodeOperation {
            operation.cancel()
        }
        processingQueue.maxConcurrentOperationCount = 1

        memoryImages.removeAllObjects()

        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self = self else { return }
            self.processingQueue.maxConcurrentOperationCount = self.limits.maxConcurrentProcessing
        }
    }

    public nonisolated func set(_ image: UIImage, for key: String, expiresIn: TimeInterval? = nil) {
        set(image, for: [key], expiresIn: expiresIn)
    }

    /// Stores one image under several keys with one resize, one encode and one
    /// file; the other keys link to that file. Keys whose file is already on
    /// disk are not written again, and when every key is on disk the image is
    /// not resized or encoded at all.
    public nonisolated func set(_ image: UIImage, for keys: [String], expiresIn: TimeInterval?) {
        // A generated placeholder is not stored (PP-5583): read back from disk
        // it loses its mark and outranks the real cover, and kept in memory it
        // answers the next fetch under the cover's key once the network is back.
        guard !image.isGeneratedCoverPlaceholder else { return }
        var seen = Set<String>()
        let keys = keys.filter { seen.insert($0).inserted }
        guard !keys.isEmpty else { return }
        let ttl = expiresIn ?? defaultTTL

        // Hoisted into an explicitly-typed `let` so the closure's type comes
        // from this annotation, not from `addOperation`'s imported parameter
        // type — which an Xcode 26.2 ClangImporter bug can poison to
        // `@MainActor` when any WebKit declaration was type-checked earlier in
        // the same swift-frontend process (batch/WMO). A @MainActor-typed
        // literal here gets a dispatch_assert_queue(main) prologue and traps
        // when processingQueue runs it off-main — the #1338 bootstrap crash.
        // Same pattern at every NSOperation-family enqueue in this file.
        let work: @Sendable () -> Void = { [weak self] in
            guard let self = self else { return }
            autoreleasepool {
                self.store(image, for: keys, ttl: ttl)
            }
        }
        processingQueue.addOperation(work)
    }

    private nonisolated func store(_ image: UIImage, for keys: [String], ttl: TimeInterval) {
        let missingKeys = keys.filter { !dataCache.hasUnexpiredDiskEntry(for: $0) }
        guard !missingKeys.isEmpty else {
            // Already on disk. Keep the in-hand image as the decoded copy when
            // it needs no resize; otherwise the next read decodes from disk.
            if let cgImage = image.cgImage, max(cgImage.width, cgImage.height) <= Int(maxDimension) {
                let cost = imageCost(image)
                for key in keys {
                    memoryImages.setObject(image, forKey: key, cost: cost)
                }
            }
            return
        }

        // Memory pressure check: Skip caching if system memory is critically low
        // to prevent NSMallocException crashes
        let availableMemory = estimateAvailableMemory()
        let minimumRequiredMemory: UInt64 = 50 * 1024 * 1024 // 50 MB minimum

        guard availableMemory > minimumRequiredMemory else {
            Log.warn(#file, "Skipping image cache due to low memory (\(availableMemory / 1024 / 1024) MB available)")
            return
        }

        guard let processed = resize(image, maxDimension: maxDimension) else {
            Log.error(#file, "Failed to resize image for keys: \(keys). Skipping cache.")
            return
        }

        let cost = imageCost(processed)

        // Check cost against available memory before proceeding
        guard UInt64(cost) < availableMemory / 2 else {
            Log.warn(#file, "Image too large for available memory: \(cost) bytes")
            return
        }

        for key in keys {
            memoryImages.setObject(processed, forKey: key, cost: cost)
        }

        let data = autoreleasepool { () -> Data? in
            encode(processed, compressionQuality)
        }
        guard let jpegData = data else {
            Log.error(#file, "Failed to compress image for keys: \(keys)")
            return
        }

        dataCache.set(jpegData, for: missingKeys, expiresIn: ttl)
    }

    /// Estimates available memory based on system resources
    /// This is an approximation - iOS doesn't expose exact available memory
    private nonisolated func estimateAvailableMemory() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            // Fall back to a conservative estimate based on total memory
            return ProcessInfo.processInfo.physicalMemory / 10
        }

        let usedMemory = info.resident_size
        let totalMemory = ProcessInfo.processInfo.physicalMemory

        // iOS apps typically can use about 25-50% of physical memory depending on device
        let maxAllowedMemory = totalMemory / 4
        let availableEstimate = maxAllowedMemory > usedMemory ? maxAllowedMemory - usedMemory : 0

        return availableEstimate
    }

    public func get(for key: String) -> UIImage? {
        // Always check memory cache first (fast, safe on any thread)
        if let img = memoryImages.object(forKey: key) {
            return img
        }

        // Skip disk I/O on main thread to prevent hangs.
        // Schedule a background promotion so the NEXT synchronous call hits
        // the memory cache. This bridges the gap between "disk has it" and
        // "memory has it" without blocking the UI thread.
        if Thread.isMainThread {
            scheduleMemoryPromotion(for: key)
            return nil
        }

        guard let data = dataCache.get(for: key) else { return nil }

        guard let img = UIImage(data: data) else {
            remove(for: key)
            return nil
        }
        let cost = imageCost(img)
        memoryImages.setObject(img, forKey: key, cost: cost)
        return img
    }

    /// Async version: checks memory first (instant), then promotes from disk
    /// on the processing queue. Use this in async contexts (registry, view model)
    /// to get disk-cached images without blocking any thread.
    public nonisolated func getAsync(for key: String) async -> UIImage? {
        if let img = memoryImages.object(forKey: key) {
            return img
        }
        return await withCheckedContinuation { continuation in
            // The continuation must resume exactly once. Every resume below
            // lives inside the operation's execution block, but
            // `handleMemoryWarning` cancels queued decode operations like this
            // one — and a cancelled `BlockOperation` never runs its block, which
            // would orphan the continuation forever (Crashlytics ab80dbb0:
            // "leaked its continuation" breadcrumb under memory pressure, where
            // each orphaned continuation pins the suspended Task + captured
            // graph and works *against* the memory relief the warning is trying
            // to achieve). A lock-guarded one-shot resume plus a completion
            // block guarantees exactly one resume whether the op runs or is
            // cancelled before it starts.
            // The one-shot resume state (lock + flag + continuation) is wrapped
            // in `OneShotImageResumer` so the `@Sendable` BlockOperation blocks
            // capture a single `Sendable` reference rather than a mutable
            // captured `var` and a local function (both illegal to capture in a
            // `@Sendable` closure under strict concurrency).
            let resumer = OneShotImageResumer(continuation)

            let operation = ImageDecodeOperation()
            // Hoisted into an explicitly-typed `let` so the closure's type
            // comes from this annotation, not from `addExecutionBlock`'s
            // imported parameter type — which the Xcode 26.2 ClangImporter
            // bug can poison to `@MainActor` (see the file-header note). A
            // @MainActor-typed literal here would dispatch_assert_queue(main)
            // and trap when processingQueue runs it off-main.
            let executionBlock: @Sendable () -> Void = { [weak self, weak operation] in
                guard let self, operation?.isCancelled != true else {
                    resumer.resume(nil)
                    return
                }
                // Double-check memory (another task may have promoted it)
                if let img = self.memoryImages.object(forKey: key) {
                    resumer.resume(img)
                    return
                }
                guard let data = self.dataCache.get(for: key) else {
                    resumer.resume(nil)
                    return
                }
                guard let img = UIImage(data: data) else {
                    self.remove(for: key)
                    resumer.resume(nil)
                    return
                }
                let cost = self.imageCost(img)
                self.memoryImages.setObject(img, forKey: key, cost: cost)
                resumer.resume(img)
            }
            operation.addExecutionBlock(executionBlock)
            // Runs for both finished and cancelled operations. If the op was
            // cancelled before its execution block ran, `resume` was never
            // called — resume here so the awaiter never hangs. The one-shot
            // guard makes this a no-op on the normal completion path.
            // Explicitly-typed for the same reason as `executionBlock` above:
            // the imported `completionBlock` property type is equally subject
            // to the ClangImporter @MainActor poisoning, and NSOperation
            // invokes it on a private background queue.
            let completion: @Sendable () -> Void = {
                resumer.resume(nil)
            }
            operation.completionBlock = completion
            processingQueue.addOperation(operation)
        }
    }

    /// Batch warm-up: promotes multiple disk-cached images into the memory
    /// cache concurrently. Call before displaying a screen full of covers.
    public func warmMemoryCache(for keys: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for key in keys {
                group.addTask { [weak self] in
                    _ = await self?.getAsync(for: key)
                }
            }
        }
    }

    /// Schedules a background disk→memory promotion for a key.
    /// Called when get() is invoked on the main thread and misses the memory cache.
    private nonisolated func scheduleMemoryPromotion(for key: String) {
        // Explicitly-typed `let` — see the comment in `set(_:for:expiresIn:)`
        // (Xcode 26.2 ClangImporter @MainActor poisoning of addOperation).
        let work: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            if self.memoryImages.object(forKey: key) != nil { return }
            guard let data = self.dataCache.get(for: key) else { return }
            guard let img = UIImage(data: data) else { return }
            let cost = self.imageCost(img)
            self.memoryImages.setObject(img, forKey: key, cost: cost)
        }
        let operation = ImageDecodeOperation()
        operation.addExecutionBlock(work)
        processingQueue.addOperation(operation)
    }

    /// The decoded image for `key` if it is in memory now. Never reads disk, so
    /// a getter can call it on the main thread.
    // PUBLIC_INTENT: witness for the public ImageCacheType requirement.
    public func memoryImage(for key: String) -> UIImage? {
        memoryImages.object(forKey: key)
    }

    public func remove(for key: String) {
        memoryImages.removeObject(forKey: key)
        dataCache.remove(for: key)
    }

    public func clear() {
        memoryImages.removeAllObjects()
        dataCache.clear()
    }

    /// Test-only: a cache with its own `processingQueue`, so a test can count
    /// exactly the operations it enqueued. The shared queue also carries the
    /// test host app's cover loads.
    internal static func _makeIsolatedForTesting(
        deviceMemoryMB: UInt64 = ProcessInfo.processInfo.physicalMemory / (1024 * 1024),
        cacheName: String = "ImageCache",
        encode: @escaping @Sendable (UIImage, CGFloat) -> Data? = { $0.jpegData(compressionQuality: $1) }
    ) -> ImageCache {
        ImageCache(deviceMemoryMB: deviceMemoryMB, cacheName: cacheName, encode: encode)
    }

    /// Test-only: where the stored data for `key` lives on disk.
    internal func _diskURLForTesting(for key: String) -> URL {
        dataCache.fileURL(for: key)
    }

    /// Test-only: restore the shared `processingQueue` to its running state.
    ///
    /// `ImageCacheContinuationTests` is the only test that suspends this
    /// singleton's queue (suspend → enqueue → cancelAllOperations → resume) to
    /// exercise the getAsync cancellation path. If that test ever aborts while
    /// the queue is suspended, the global queue stays suspended and every later
    /// `ImageCache.shared.getAsync` hangs to timeout — surfacing as a different
    /// flaky victim each run (the test-isolation-family signature). Registering
    /// this with `SingletonResetRegistry` makes the queue restore after EVERY
    /// test via the finished-test observer, independent of that one test's
    /// tearDown. `internal` (not `#if DEBUG`) matches the
    /// `AppContainer._resetForTesting` convention and the blast-radius gate.
    internal func _resetForTesting() {
        processingQueue.cancelAllOperations()
        processingQueue.isSuspended = false
    }

    /// Bytes of decoded images held in memory now (PP-5509).
    var decodedImageBytes: Int { memoryImages.byteCount }

    /// Bytes of compressed image data held in memory now (PP-5509).
    var compressedDataMemoryBytes: Int { dataCache.memoryBytes }

    /// Evict decoded in-memory images without touching the compressed disk
    /// cache. The disk cache retains JPEG data, so the next fetchCoverImage
    /// call promotes from disk (~5ms) instead of hitting the network.
    /// NSCache also auto-evicts under memory pressure independently.
    public func evictDecodedImages() {
        memoryImages.removeAllObjects()
    }

    private nonisolated func resize(_ image: UIImage, maxDimension: CGFloat) -> UIImage? {
        let size = image.size
        guard size.width > 0 && size.height > 0 else { return image }
        let maxSide = max(size.width, size.height)
        if maxSide <= maxDimension { return image }

        let scale = maxDimension / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        guard newSize.width > 0 && newSize.height > 0 else {
            Log.error(#file, "Invalid resize dimensions: \(newSize)")
            return image
        }

        return autoreleasepool {
            guard let cgImage = image.cgImage else {
                Log.error(#file, "Failed to get CGImage from UIImage")
                return image
            }

            // Always use sRGB color space to ensure compatibility with all image types
            // Source images may be CMYK, grayscale, or other unsupported formats
            let colorSpace = CGColorSpaceCreateDeviceRGB()

            // Use premultiplied alpha which is universally supported by CGContext
            // This handles RGB without alpha, CMYK, and other unusual formats
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

            guard let context = CGContext(
                data: nil,
                width: Int(newSize.width),
                height: Int(newSize.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                Log.error(#file, "Failed to create CGContext for resize. Returning original image.")
                return image
            }

            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(origin: .zero, size: newSize))

            guard let resizedCGImage = context.makeImage() else {
                Log.error(#file, "Failed to create resized CGImage")
                return image
            }

            return UIImage(cgImage: resizedCGImage, scale: 1.0, orientation: image.imageOrientation)
        }
    }

    private nonisolated func imageCost(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }
}
