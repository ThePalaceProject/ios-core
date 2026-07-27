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

/// `@unchecked Sendable` invariant: every stored property is either an
/// immutable `let` (`defaultTTL`, `maxDimension`, `compressionQuality`) or a
/// reference to a type that is itself internally thread-safe — `NSCache`
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
/// The fix works because the closure's type comes from the `let` ANNOTATION
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

    private let dataCache = GeneralCache<String, Data>(cacheName: "ImageCache", mode: .memoryAndDisk)
    private let memoryImages = NSCache<NSString, UIImage>()
    private let defaultTTL: TimeInterval = 14 * 24 * 60 * 60
    private let maxDimension: CGFloat
    private let compressionQuality: CGFloat = 0.7
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

    private init() {
        let deviceMemoryMB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)
        let cacheMemoryMB: Int
        let maxConcurrentProcessing: Int

        // Cover art in catalog lanes displays at ~100pt (300px @3x).
        // Each 300x300 RGBA decoded = ~360KB. A typical catalog has 15 lanes
        // × 7 visible books = ~105 covers across All/Ebooks/Audiobooks.
        // The NSCache must hold enough to avoid re-fetching on entry point
        // switches. Memory is reclaimed on library switch via evictAllDecodedImages().
        if deviceMemoryMB < 2048 {
            cacheMemoryMB = 15
            memoryImages.countLimit = 60
            maxDimension = 200
            maxConcurrentProcessing = 2
        } else if deviceMemoryMB < 4096 {
            cacheMemoryMB = 25
            memoryImages.countLimit = 100
            maxDimension = 300
            maxConcurrentProcessing = 3
        } else {
            cacheMemoryMB = 40
            memoryImages.countLimit = 150
            maxDimension = 300
            maxConcurrentProcessing = 4
        }

        processingQueue.maxConcurrentOperationCount = maxConcurrentProcessing
        memoryImages.totalCostLimit = cacheMemoryMB * 1024 * 1024

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    @objc private func handleMemoryWarning() {
        processingQueue.cancelAllOperations()
        processingQueue.maxConcurrentOperationCount = 1

        memoryImages.removeAllObjects()
        dataCache.clearMemory()

        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self = self else { return }
            let deviceMemoryMB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)
            if deviceMemoryMB < 2048 {
                self.processingQueue.maxConcurrentOperationCount = 2
            } else if deviceMemoryMB < 4096 {
                self.processingQueue.maxConcurrentOperationCount = 3
            } else {
                self.processingQueue.maxConcurrentOperationCount = 4
            }
        }
    }

    public nonisolated func set(_ image: UIImage, for key: String, expiresIn: TimeInterval? = nil) {
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
                // Memory pressure check: Skip caching if system memory is critically low
                // to prevent NSMallocException crashes
                let availableMemory = self.estimateAvailableMemory()
                let minimumRequiredMemory: UInt64 = 50 * 1024 * 1024 // 50 MB minimum

                guard availableMemory > minimumRequiredMemory else {
                    Log.warn(#file, "Skipping image cache due to low memory (\(availableMemory / 1024 / 1024) MB available)")
                    return
                }

                guard let processed = self.resize(image, maxDimension: self.maxDimension) else {
                    Log.error(#file, "Failed to resize image for key: \(key). Skipping cache.")
                    return
                }

                let cost = self.imageCost(processed)

                // Check cost against available memory before proceeding
                guard UInt64(cost) < availableMemory / 2 else {
                    Log.warn(#file, "Image too large for available memory: \(cost) bytes")
                    return
                }

                self.memoryImages.setObject(processed, forKey: key as NSString, cost: cost)

                // Wrap JPEG data creation in exception handling to catch NSMallocException
                var data: Data?
                do {
                    data = try autoreleasepool { () -> Data? in
                        processed.jpegData(compressionQuality: self.compressionQuality)
                    }
                } catch {
                    Log.error(#file, "Exception creating JPEG data for key: \(key) - \(error)")
                    return
                }

                guard let jpegData = data else {
                    Log.error(#file, "Failed to compress image for key: \(key)")
                    return
                }

                self.dataCache.set(jpegData, for: key, expiresIn: ttl)
            }
        }
        processingQueue.addOperation(work)
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
        if let img = memoryImages.object(forKey: key as NSString) {
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
        memoryImages.setObject(img, forKey: key as NSString, cost: cost)
        return img
    }

    /// Async version: checks memory first (instant), then promotes from disk
    /// on the processing queue. Use this in async contexts (registry, view model)
    /// to get disk-cached images without blocking any thread.
    public nonisolated func getAsync(for key: String) async -> UIImage? {
        if let img = memoryImages.object(forKey: key as NSString) {
            return img
        }
        return await withCheckedContinuation { continuation in
            // The continuation must resume exactly once. Every resume below
            // lives inside the operation's execution block, but
            // `handleMemoryWarning` calls `processingQueue.cancelAllOperations()`
            // — and a cancelled `BlockOperation` never runs its block, which
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

            let operation = BlockOperation()
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
                if let img = self.memoryImages.object(forKey: key as NSString) {
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
                self.memoryImages.setObject(img, forKey: key as NSString, cost: cost)
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
            if self.memoryImages.object(forKey: key as NSString) != nil { return }
            guard let data = self.dataCache.get(for: key) else { return }
            guard let img = UIImage(data: data) else { return }
            let cost = self.imageCost(img)
            self.memoryImages.setObject(img, forKey: key as NSString, cost: cost)
        }
        processingQueue.addOperation(work)
    }

    public func remove(for key: String) {
        memoryImages.removeObject(forKey: key as NSString)
        dataCache.remove(for: key)
    }

    public func clear() {
        memoryImages.removeAllObjects()
        dataCache.clear()
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
