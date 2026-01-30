import Foundation
import UIKit

// MARK: - Swift Concurrency Actor
actor TPPBookCoverRegistry {
  let imageCache: ImageCacheType
  
  static let shared = TPPBookCoverRegistry(imageCache: ImageCache.shared)
  
  private var inProgressTasks: [URL: Task<UIImage?, Never>] = [:]
  init(imageCache: ImageCacheType) {
    self.imageCache = imageCache
  }
  
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
  
  private func fetchImage(from url: URL, for book: TPPBook, isCover: Bool) async -> UIImage? {
    let key = cacheKey(for: book, isCover: isCover)
    if let img = imageCache.get(for: key as String) {
      return img
    }
    
    if let existing = inProgressTasks[url] {
      return await existing.value
    }
    
    let task = Task<UIImage?, Never> { [weak self] in
      guard let self else { return nil }
      
      do {
        let (data, _) = try await URLSession.shared.data(from: url)
        
        // Decode image in background to prevent main thread blocking
        guard let image = await self.decodeImageInBackground(data) else {
          Log.error(#file, "Failed to decode image data from URL: \(url)")
          return nil
        }
        
        self.imageCache.set(image, for: key as String, expiresIn: nil)
        return image
      } catch {
        Log.error(#file, "Failed to fetch image from \(url): \(error.localizedDescription)")
        return nil
      }
    }
    
    inProgressTasks[url] = task
    let image = await task.value
    
    inProgressTasks[url] = nil
    
    return image
  }
  
  // MARK: - Background Image Decoding
  
  /// Decodes image data off the main thread using iOS 15+ optimized API
  /// This prevents main thread hitching when displaying images
  private func decodeImageInBackground(_ data: Data) async -> UIImage? {
    await Task.detached(priority: .userInitiated) {
      guard let image = UIImage(data: data) else { return nil }
      
      // byPreparingForDisplay() decodes the image and prepares it for rendering
      // This is the iOS 15+ way to force decode off main thread
      if #available(iOS 15.0, *) {
        return await image.byPreparingForDisplay()
      } else {
        // Fallback for iOS 14: force decode by drawing into a context
        return self.forceDecodeImage(image)
      }
    }.value
  }
  
  /// Force decode image for iOS 14 compatibility
  /// Drawing into a context forces the image to be decoded
  private nonisolated func forceDecodeImage(_ image: UIImage) -> UIImage {
    guard let cgImage = image.cgImage else { return image }
    
    let width = cgImage.width
    let height = cgImage.height
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    
    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else {
      return image
    }
    
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    
    guard let decodedCGImage = context.makeImage() else {
      return image
    }
    
    return UIImage(cgImage: decodedCGImage, scale: image.scale, orientation: image.imageOrientation)
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
    
    // Check for existing in-progress task
    if let existing = inProgressTasks[url] {
      return await existing.value
    }
    
    let task = Task<UIImage?, Never> { [weak self] in
      guard let self else { return nil }
      
      do {
        let (data, _) = try await URLSession.shared.data(from: url)
        
        // Decode image in background to prevent main thread blocking
        guard let image = await self.decodeImageInBackground(data) else {
          Log.error(#file, "Failed to decode image data from URL: \(url)")
          return nil
        }
        
        self.imageCache.set(image, for: key, expiresIn: nil)
        return image
      } catch {
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
  @objc public func coverImageForBook(_ book: TPPBook, completion: @escaping (UIImage?) -> Void) {
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
  @objc public func thumbnailImageForBook(_ book: TPPBook, completion: @escaping (UIImage?) -> Void) {
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
