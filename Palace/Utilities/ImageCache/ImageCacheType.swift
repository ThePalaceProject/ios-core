import UIKit
import PalaceLogging

public protocol ImageCacheType {
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

public final class ImageCache: ImageCacheType {
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

    public func set(_ image: UIImage, for key: String, expiresIn: TimeInterval? = nil) {
        let ttl = expiresIn ?? defaultTTL

        processingQueue.addOperation { [weak self] in
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
    }

    /// Estimates available memory based on system resources
    /// This is an approximation - iOS doesn't expose exact available memory
    private func estimateAvailableMemory() -> UInt64 {
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
    public func getAsync(for key: String) async -> UIImage? {
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
            let resumeLock = NSLock()
            var hasResumed = false
            func resumeOnce(_ image: UIImage?) {
                resumeLock.lock()
                defer { resumeLock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(returning: image)
            }

            let operation = BlockOperation()
            operation.addExecutionBlock { [weak self, weak operation] in
                guard let self, operation?.isCancelled != true else {
                    resumeOnce(nil)
                    return
                }
                // Double-check memory (another task may have promoted it)
                if let img = self.memoryImages.object(forKey: key as NSString) {
                    resumeOnce(img)
                    return
                }
                guard let data = self.dataCache.get(for: key) else {
                    resumeOnce(nil)
                    return
                }
                guard let img = UIImage(data: data) else {
                    self.remove(for: key)
                    resumeOnce(nil)
                    return
                }
                let cost = self.imageCost(img)
                self.memoryImages.setObject(img, forKey: key as NSString, cost: cost)
                resumeOnce(img)
            }
            // Runs for both finished and cancelled operations. If the op was
            // cancelled before its execution block ran, `resumeOnce` was never
            // called — resume here so the awaiter never hangs. The one-shot
            // guard makes this a no-op on the normal completion path.
            operation.completionBlock = {
                resumeOnce(nil)
            }
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
    private func scheduleMemoryPromotion(for key: String) {
        processingQueue.addOperation { [weak self] in
            guard let self else { return }
            if self.memoryImages.object(forKey: key as NSString) != nil { return }
            guard let data = self.dataCache.get(for: key) else { return }
            guard let img = UIImage(data: data) else { return }
            let cost = self.imageCost(img)
            self.memoryImages.setObject(img, forKey: key as NSString, cost: cost)
        }
    }

    public func remove(for key: String) {
        memoryImages.removeObject(forKey: key as NSString)
        dataCache.remove(for: key)
    }

    public func clear() {
        memoryImages.removeAllObjects()
        dataCache.clear()
    }

    /// Evict decoded in-memory images without touching the compressed disk
    /// cache. The disk cache retains JPEG data, so the next fetchCoverImage
    /// call promotes from disk (~5ms) instead of hitting the network.
    /// NSCache also auto-evicts under memory pressure independently.
    public func evictDecodedImages() {
        memoryImages.removeAllObjects()
    }

    private func resize(_ image: UIImage, maxDimension: CGFloat) -> UIImage? {
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

    private func imageCost(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }
}
