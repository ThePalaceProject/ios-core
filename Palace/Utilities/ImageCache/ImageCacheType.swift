import UIKit

public protocol ImageCacheType {
    func set(_ image: UIImage, for key: String, expiresIn: TimeInterval?)
    func get(for key: String) -> UIImage?
    func remove(for key: String)
    func clear()
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
    private let processingQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .utility
        queue.name = "org.thepalaceproject.imageprocessing"
        return queue
    }()

    private init() {
        let deviceMemoryMB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)
        let cacheMemoryMB: Int
        let maxConcurrentProcessing: Int
        
        if deviceMemoryMB < 2048 {
            cacheMemoryMB = 25
            memoryImages.countLimit = 100
            maxDimension = 512
            maxConcurrentProcessing = 2
        } else if deviceMemoryMB < 4096 {
            cacheMemoryMB = 40
            memoryImages.countLimit = 150
            maxDimension = 768
            maxConcurrentProcessing = 3
        } else {
            cacheMemoryMB = 60
            memoryImages.countLimit = 200
            maxDimension = 1024
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
        if let img = memoryImages.object(forKey: key as NSString) {
            return img
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

    public func remove(for key: String) {
        memoryImages.removeObject(forKey: key as NSString)
        dataCache.remove(for: key)
    }

    public func clear() {
        memoryImages.removeAllObjects()
        dataCache.clear()
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
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            
            guard let cgImage = image.cgImage else {
                Log.error(#file, "Failed to get CGImage from UIImage")
                return image
            }
            
            let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = cgImage.bitmapInfo
            
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
