import UIKit
import ImageIO
import UniformTypeIdentifiers

public protocol ImageCacheType {
  func set(_ image: UIImage, for key: String, expiresIn: TimeInterval?)
  func get(for key: String) -> UIImage?
  func remove(for key: String)
  func clear()
}

public extension ImageCacheType {
  /// Default 14-day expiration if you omit `expiresIn`
  func set(_ image: UIImage, for key: String) {
    let fourteenDays: TimeInterval = 14 * 24 * 60 * 60
    set(image, for: key, expiresIn: fourteenDays)
  }
}

/// A thread-safe image cache with in-memory LRU, disk persistence via ImageIO streaming,
/// expiration based on file modification date, and background cleanup.
public final class ImageCache: ImageCacheType {
  public static let shared = ImageCache()

  // MARK: - Configuration
  private let defaultTTL: TimeInterval = 14 * 24 * 60 * 60 // 14 days
  private let memoryCostLimit: Int = 100 * 1024 * 1024      // ~100 MB
  private let memoryCountLimit: Int = 200                   // max 200 images

  // MARK: - Storage
  private let memoryImages = NSCache<NSString, UIImage>()
  private let fileManager = FileManager.default
  private let cacheDirectory: URL
  private let ioQueue = DispatchQueue(label: "com.myapp.imagecache.io")

  // MARK: - Init
  private init() {
    // Configure in-memory cache limits
    memoryImages.totalCostLimit = memoryCostLimit
    memoryImages.countLimit = memoryCountLimit
    
    // Prepare disk cache directory
    let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
    cacheDirectory = cachesURL.appendingPathComponent("ImageCache", isDirectory: true)
    try? fileManager.createDirectory(at: cacheDirectory,
                                     withIntermediateDirectories: true)
    
    // Initial cleanup
    cleanupExpiredFiles()
    
    // Cleanup on app foreground
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(cleanupExpiredFiles),
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
    
    // Clear memory on warning
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleMemoryWarning),
      name: UIApplication.didReceiveMemoryWarningNotification,
      object: nil
    )
  }

  @objc private func handleMemoryWarning() {
    memoryImages.removeAllObjects()
  }

  // MARK: - Public API
  public func set(_ image: UIImage, for key: String, expiresIn: TimeInterval? = nil) {
    let ttl = expiresIn ?? defaultTTL
    let cost = imageCost(image)
    memoryImages.setObject(image, forKey: key as NSString, cost: cost)
    
    // Stream to disk asynchronously
    ioQueue.async { [weak self] in
      guard let self = self, let cgImage = image.cgImage else { return }
      autoreleasepool {
        let url = self.fileURL(for: key)
        // Use JPEG streaming to avoid large pngData() alloc
        let uti = UTType.jpeg.identifier as CFString
        let options = [ kCGImageDestinationLossyCompressionQuality: 0.8 ] as CFDictionary
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, uti, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cgImage, options)
        guard CGImageDestinationFinalize(dest) else { return }
        // Set modification date to now + ttl for expiration
        let expDate = Date().addingTimeInterval(ttl)
        try? self.fileManager.setAttributes([
          .modificationDate: expDate
        ], ofItemAtPath: url.path)
      }
    }
  }

  public func get(for key: String) -> UIImage? {
    // 1) Check in-memory cache
    if let image = memoryImages.object(forKey: key as NSString) {
      return image
    }
    
    // 2) Check disk cache
    let url = fileURL(for: key)
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    
    // Validate expiration
    if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
       let modDate = attrs[.modificationDate] as? Date,
       modDate <= Date() {
      // expired
      remove(for: key)
      return nil
    }
    
    // Lazy load image
    guard let image = UIImage(contentsOfFile: url.path) else { return nil }
    
    // Prime in-memory cache
    let cost = imageCost(image)
    memoryImages.setObject(image, forKey: key as NSString, cost: cost)
    return image
  }

  public func remove(for key: String) {
    memoryImages.removeObject(forKey: key as NSString)
    let url = fileURL(for: key)
    ioQueue.async {
      try? self.fileManager.removeItem(at: url)
    }
  }

  public func clear() {
    memoryImages.removeAllObjects()
    ioQueue.async {
      let files = (try? self.fileManager.contentsOfDirectory(at: self.cacheDirectory,
                                                             includingPropertiesForKeys: nil,
                                                             options: [])) ?? []
      for url in files { try? self.fileManager.removeItem(at: url) }
    }
  }

  // MARK: - Cleanup
  @objc private func cleanupExpiredFiles() {
    ioQueue.async { [weak self] in
      guard let self = self else { return }
      let now = Date()
      let files = (try? self.fileManager.contentsOfDirectory(at: self.cacheDirectory,
                                                              includingPropertiesForKeys: [.contentModificationDateKey],
                                                              options: [])) ?? []
      for url in files {
        if let attrs = try? self.fileManager.attributesOfItem(atPath: url.path),
           let modDate = attrs[.modificationDate] as? Date,
           modDate <= now {
          try? self.fileManager.removeItem(at: url)
        }
      }
    }
  }

  // MARK: - Helpers
  private func fileURL(for key: String) -> URL {
    let safeFilename = key
      .replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "", options: .regularExpression)
    return cacheDirectory.appendingPathComponent(safeFilename).appendingPathExtension("jpg")
  }

  private func imageCost(_ image: UIImage) -> Int {
    guard let cg = image.cgImage else { return 1 }
    return cg.bytesPerRow * cg.height
  }
}
