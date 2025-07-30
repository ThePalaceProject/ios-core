import Foundation
import UIKit

// MARK: - Swift Concurrency Actor
actor TPPBookCoverRegistry {
  static let shared = TPPBookCoverRegistry()
  
  private let isCachingEnabled: Bool = ProcessInfo.processInfo.physicalMemory >= 2 * 1024 * 1024 * 1024
  private let memoryCache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 100
    cache.totalCostLimit = 10 * 1024 * 1024
    return cache
  }()
  private let diskCacheURL: URL? = {
    let fm = FileManager.default
    guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
    let dir = caches.appendingPathComponent("TPPBookCovers", isDirectory: true)
    
    do {
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
      return dir
    } catch {
      Log.error(#file, "Failed to create book cover cache directory: \(error.localizedDescription)")
      return nil
    }
  }()
  private let diskQueue = DispatchQueue(label: "com.thepalaceproject.TPPBookCoverRegistry.diskQueue")
  private var inProgressTasks: [URL: Task<UIImage?, Never>] = [:]
  
  func coverImage(for book: TPPBook) async -> UIImage? {
    guard let url = book.imageURL else { return await thumbnailImage(for: book) }
    return await fetchImage(from: url, for: book, isCover: true)
  }
  
  func thumbnailImage(for book: TPPBook) async -> UIImage? {
    guard let url = book.imageThumbnailURL else {
      return await placeholder(for: book)
    }
    
    return await fetchImage(from: url, for: book, isCover: false)
  }
  
  private func fetchImage(from url: URL, for book: TPPBook, isCover: Bool) async -> UIImage? {
    let key = cacheKey(for: book, isCover: isCover)
    
    if isCachingEnabled, let img = memoryCache.object(forKey: key) { 
      return img 
    }
    
    if isCachingEnabled,
       let fileURL = diskCacheURL?.appendingPathComponent(key as String),
       let data = try? Data(contentsOf: fileURL),
       let img = UIImage(data: data) {
      memoryCache.setObject(img, forKey: key, cost: cost(for: img))
      return img
    }
    
    if let existing = inProgressTasks[url] {
      return await existing.value
    }
    
    let task = Task<UIImage?, Never> { [weak self] in
      guard let self = self else { return nil }
      
      do {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let image = UIImage(data: data) else { return nil }
        
        await self.store(image: image, forKey: key)
        return image
      } catch {
        Log.error(#file, "Failed to fetch image: \(error.localizedDescription)")
        return nil
      }
    }
    
    inProgressTasks[url] = task
    let image = await task.value
    
    inProgressTasks[url] = nil
    
    return image
  }
  
  private func store(image: UIImage, forKey key: NSString) async {
    guard isCachingEnabled else { return }

    memoryCache.setObject(image, forKey: key, cost: cost(for: image))

    if let dir = diskCacheURL,
       let data = image.jpegData(compressionQuality: 0.8) {
      let destination = dir.appendingPathComponent(key as String)
      
      await withCheckedContinuation { continuation in
        diskQueue.async {
          do {
            // Ensure parent directory still exists
            let parentDir = destination.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parentDir.path) {
              try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            
            try data.write(to: destination)
            continuation.resume()
          } catch {
            Log.error(#file, "Failed to write image cache file '\(destination.lastPathComponent)' to disk: \(error.localizedDescription). Directory: \(destination.deletingLastPathComponent().path)")
            continuation.resume()
          }
        }
      }
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
}


// MARK: - Objective-C Bridge
@objcMembers
public class TPPBookCoverRegistryBridge: NSObject {
  public static let shared = TPPBookCoverRegistryBridge()
  
  /// Asynchronous, Objective-C friendly cover fetch
  /// - Parameters:
  ///   - book: The TPPBook instance
  ///   - completion: Block called on main thread with the UIImage or nil
  @objc public func coverImageForBook(_ book: TPPBook, completion: @escaping (UIImage?) -> Void) {
    Task {
      let img = await TPPBookCoverRegistry.shared.coverImage(for: book)
      DispatchQueue.main.async { completion(img) }
    }
  }
  
  /// Asynchronous, Objective-C friendly thumbnail fetch
  @objc public func thumbnailImageForBook(_ book: TPPBook, completion: @escaping (UIImage?) -> Void) {
    Task {
      let img = await TPPBookCoverRegistry.shared.thumbnailImage(for: book)
      DispatchQueue.main.async { completion(img) }
    }
  }
}
