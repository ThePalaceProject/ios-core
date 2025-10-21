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

    private init() {
        let deviceMemoryMB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)
        let cacheMemoryMB: Int
        
        if deviceMemoryMB < 2048 {
            cacheMemoryMB = 25
            memoryImages.countLimit = 100
            maxDimension = 512
        } else if deviceMemoryMB < 4096 {
            cacheMemoryMB = 40
            memoryImages.countLimit = 150
            maxDimension = 768
        } else {
            cacheMemoryMB = 60
            memoryImages.countLimit = 200
            maxDimension = 1024
        }
        
        memoryImages.totalCostLimit = cacheMemoryMB * 1024 * 1024
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryPressure),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }
    
    @objc private func handleMemoryPressure() {
        let currentCount = memoryImages.countLimit
        memoryImages.countLimit = max(50, currentCount / 2)
        memoryImages.totalCostLimit = memoryImages.totalCostLimit / 2
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.memoryImages.countLimit = currentCount
        }
    }

    @objc private func handleMemoryWarning() {
        memoryImages.removeAllObjects()
        dataCache.clearMemory()
    }

    public func set(_ image: UIImage, for key: String, expiresIn: TimeInterval? = nil) {
        let ttl = expiresIn ?? defaultTTL
        
        guard let processed = resize(image, maxDimension: maxDimension) else {
            Log.error(#file, "Failed to resize image for key: \(key). Skipping cache.")
            return
        }
        
        let cost = imageCost(processed)
        memoryImages.setObject(processed, forKey: key as NSString, cost: cost)
        
        DispatchQueue.global(qos: .utility).async {
            guard let data = processed.jpegData(compressionQuality: self.compressionQuality) else { return }
            self.dataCache.set(data, for: key, expiresIn: ttl)
        }
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
