import Foundation
import UIKit

class TPPBookCoverRegistry {

  // MARK: - Properties

  private let cache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 100
    return cache
  }()

  private lazy var urlSession: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.httpCookieStorage = nil
    configuration.httpMaximumConnectionsPerHost = 8
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 30
    configuration.urlCache = URLCache(memoryCapacity: 2 * 1024 * 1024, diskCapacity: 16 * 1024 * 1024)
    configuration.urlCredentialStorage = nil
    return URLSession(configuration: configuration)
  }()

  private let cacheQueue = DispatchQueue(label: "com.thepalaceproject.TPPBookCoverRegistry.cacheQueue", attributes: .concurrent)

  private let fileManager = FileManager.default

  // MARK: - Public Methods

  @MainActor
  func thumbnailImageForBook(_ book: TPPBook, handler: @escaping (_ image: UIImage?) -> Void) {
    if let cachedImage = cachedImage(for: book, isCover: false) {
      handler(cachedImage)
      return
    }

    if let localImage = loadImageFromDisk(for: book, isCover: false) {
      cacheImage(localImage, for: book, isCover: false) // Cache for quick reuse
      handler(localImage)
      return
    }

    guard let thumbnailUrl = book.imageThumbnailURL else {
      DispatchQueue.main.async {
        handler(self.generateBookCoverImage(book))
      }
      return
    }

    fetchImage(from: thumbnailUrl) { [weak self] image in
      guard let self = self else {
        handler(nil)
        return
      }

      let finalImage = image ?? self.generateBookCoverImage(book)
      if let finalImage = finalImage {
        self.cacheImage(finalImage, for: book, isCover: false)
        self.saveImageToDisk(finalImage, for: book, isCover: false)
      }
      handler(finalImage)
    }
  }


  @MainActor
  func thumbnailImagesForBooks(_ books: Set<TPPBook>, handler: @escaping (_ bookIdentifiersToImages: [String: UIImage]) -> Void) {
    var result: [String: UIImage] = [:]
    let dispatchGroup = DispatchGroup()

    for book in books {
      dispatchGroup.enter()
      thumbnailImageForBook(book) { image in
        if let image = image {
          result[book.identifier] = image
        }
        dispatchGroup.leave()
      }
    }

    dispatchGroup.notify(queue: .main) {
      handler(result)
    }
  }

  @MainActor
  func coverImageForBook(_ book: TPPBook, handler: @escaping (_ image: UIImage?) -> Void) {
    if let cachedImage = cachedImage(for: book, isCover: true) {
      handler(cachedImage)
      return
    }

    if let localImage = loadImageFromDisk(for: book, isCover: true) {
      cacheImage(localImage, for: book, isCover: true)
      handler(localImage)
      return
    }

    guard let imageUrl = book.imageURL else {
      thumbnailImageForBook(book) { handler($0) }
      return
    }

    fetchImage(from: imageUrl) { image in
      if let image {
        self.cacheImage(image, for: book, isCover: true)
        self.saveImageToDisk(image, for: book, isCover: true)
        DispatchQueue.main.async {
          handler(image)
        }
      }
    }
  }

  @discardableResult
  func cachedThumbnailImageForBook(_ book: TPPBook) -> UIImage? {
    return cachedImage(for: book, isCover: false)
  }

  // MARK: - Private Methods

  private func cachedImage(for book: TPPBook, isCover: Bool) -> UIImage? {
    let key = cacheKey(for: book, isCover: isCover)
    return cache.object(forKey: key as NSString)
  }

  private func cacheImage(_ image: UIImage, for book: TPPBook, isCover: Bool) {
    let key = cacheKey(for: book, isCover: isCover)
    cache.setObject(image, forKey: key as NSString)
  }

  private func loadImageFromDisk(for book: TPPBook, isCover: Bool) -> UIImage? {
    guard let imagePath = imageFileURL(for: book, isCover: isCover)?.path,
          fileManager.fileExists(atPath: imagePath) else {
      return nil
    }
    return UIImage(contentsOfFile: imagePath)
  }

  private func saveImageToDisk(_ image: UIImage, for book: TPPBook, isCover: Bool) {
    guard let fileUrl = imageFileURL(for: book, isCover: isCover),
          let data = image.jpegData(compressionQuality: 0.85) else { return }

    DispatchQueue.global(qos: .background).async {
      do {
        try data.write(to: fileUrl, options: .atomic)
      } catch {
        ATLog(.error, "Failed to write image to file: \(error.localizedDescription)")
      }
    }
  }

  private func fetchImage(from url: URL, completion: @escaping (_ image: UIImage?) -> Void) {
    urlSession.dataTask(with: url) { data, _, error in

      if let error = error {
        ATLog(.error, "Failed to load image from \(url): \(error.localizedDescription)")
        DispatchQueue.main.async { completion(nil) }
        return
      }

      guard let data = data, let image = UIImage(data: data) else {
        ATLog(.error, "Failed to create image from data at \(url)")
        DispatchQueue.main.async { completion(nil) }
        return
      }

      DispatchQueue.main.async {
        completion(image)
      }
    }.resume()
  }

  private func generateBookCoverImage(_ book: TPPBook) -> UIImage? {
    let width: CGFloat = 80
    let height: CGFloat = 120
    let coverView = NYPLTenPrintCoverView(frame: CGRect(x: 0, y: 0, width: width, height: height),
                                          withTitle: book.title,
                                          withAuthor: book.authors,
                                          withScale: 0.4)

    UIGraphicsBeginImageContextWithOptions(CGSize(width: width, height: height), true, 0)
    defer { UIGraphicsEndImageContext() }

    guard let context = UIGraphicsGetCurrentContext(), let coverView = coverView else {
      return nil
    }

    coverView.layer.render(in: context)
    return UIGraphicsGetImageFromCurrentImageContext()
  }

  private func cacheKey(for book: TPPBook, isCover: Bool) -> String {
    return "\(book.identifier)_\(isCover ? "cover" : "thumbnail")"
  }

  private func imageFileURL(for book: TPPBook, isCover: Bool) -> URL? {
    let filename = "\(book.identifier)_\(isCover ? "cover" : "thumbnail").jpg"
    return imagesDirectoryURL?.appendingPathComponent(filename)
  }

  private var imagesDirectoryURL: URL? {
    let urls = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
    let imagesDir = urls.first?.appendingPathComponent("book_covers")
    try? fileManager.createDirectory(at: imagesDir!, withIntermediateDirectories: true)
    return imagesDir
  }

  // MARK: - Cache Cleanup

  func cleanUpOldImages() {
    DispatchQueue.global(qos: .background).async {
      guard let imagesDir = self.imagesDirectoryURL else { return }

      do {
        let fileURLs = try self.fileManager.contentsOfDirectory(at: imagesDir, includingPropertiesForKeys: nil)
        let expirationDate = Date().addingTimeInterval(-7 * 24 * 60 * 60) // 7 days

        for fileURL in fileURLs {
          let attributes = try self.fileManager.attributesOfItem(atPath: fileURL.path)
          if let modificationDate = attributes[.modificationDate] as? Date, modificationDate < expirationDate {
            try self.fileManager.removeItem(at: fileURL)
          }
        }
      } catch {
        ATLog(.error, "Failed to clean up old images: \(error.localizedDescription)")
      }
    }
  }
}
