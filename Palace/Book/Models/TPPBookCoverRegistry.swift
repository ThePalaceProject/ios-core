import Foundation
import UIKit

class TPPBookCoverRegistry {

  // MARK: - Properties

  private let cache: NSCache<NSString, UIImage> = {
    let c = NSCache<NSString, UIImage>()
    c.countLimit     = 50
    c.totalCostLimit = 2 * 1024 * 1024
    return c
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

  private let fileManager = FileManager.default
  private let cacheQueue = DispatchQueue(label: "com.thepalaceproject.TPPBookCoverRegistry.cacheQueue", attributes: .concurrent)

  private let operationQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "com.thepalaceproject.TPPBookCoverRegistry.downloadQueue"
    queue.maxConcurrentOperationCount = 4
    return queue
  }()

  private var inProgressRequests: [URL: [(_ image: UIImage?) -> Void]] = [:]
  private let requestsLock = NSLock()

  // MARK: - Initialization

  static var shared = TPPBookCoverRegistry()

  init() {
    cleanUpOldImages()
    NotificationCenter.default.addObserver(self, selector: #selector(clearMemoryCache), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Public Methods

  func thumbnailImageForBook(_ book: TPPBook, handler: @escaping (_ image: UIImage?) -> Void) {
    if let cachedImage = cachedImage(for: book, isCover: false) {
      DispatchQueue.main.async { handler(cachedImage) }
      return
    }

    guard let thumbnailUrl = book.imageThumbnailURL else {
      let generatedImage = generateBookCoverImage(book)
      DispatchQueue.main.async { handler(generatedImage) }
      
      if let generatedImage = generatedImage {
        cacheImage(generatedImage, for: book, isCover: false)
      }
      return
    }

    fetchImage(from: thumbnailUrl) { [weak self] image in
      guard let self = self else {
        DispatchQueue.main.async { handler(nil) }
        return
      }

      let finalImage = image ?? self.generateBookCoverImage(book)
      if let finalImage = finalImage {
        self.cacheImage(finalImage, for: book, isCover: false)
      }
      DispatchQueue.main.async { handler(finalImage) }
    }
  }

  func coverImageForBook(_ book: TPPBook, handler: @escaping (_ image: UIImage?) -> Void) {
    if let cachedImage = cachedImage(for: book, isCover: true) {
      DispatchQueue.main.async { handler(cachedImage) }
      return
    }

    guard let imageUrl = book.imageURL else {
      if cachedImage(for: book, isCover: false) == nil {
        thumbnailImageForBook(book, handler: handler)
      }
      return
    }

    fetchImage(from: imageUrl) { [weak self] image in
      guard let self = self else {
        DispatchQueue.main.async {  handler(nil) }
        return
      }

      if let image = image {
        self.cacheImage(image, for: book, isCover: true)
      }
      DispatchQueue.main.async { handler(image) }
    }
  }

  @MainActor
  func thumbnailImagesForBooks(
    _ books: Set<TPPBook>,
    handler: @escaping (_ bookIdentifiersToImages: [String: UIImage]) -> Void
  ) {
    var result: [String: UIImage] = [:]
    let total = books.count
    var completed = 0

    guard total > 0 else {
      handler(result)
      return
    }

    for book in books {
      self.thumbnailImageForBook(book) { image in
        if let image = image {
          result[book.identifier] = image
        }
        completed += 1

        if completed == total {
          handler(result)
        }
      }
    }
  }

  @discardableResult
  func cachedThumbnailImageForBook(_ book: TPPBook) -> UIImage? {
    return cachedImage(for: book, isCover: false)
  }

  func cancelImageDownloadsForBook(_ book: TPPBook) {
    if let thumbnailUrl = book.imageThumbnailURL {
      cancelImageDownload(for: thumbnailUrl)
    }

    if let coverUrl = book.imageURL {
      cancelImageDownload(for: coverUrl)
    }
  }

  // MARK: - Private Methods

  private func cachedImage(for book: TPPBook, isCover: Bool) -> UIImage? {
    let key = cacheKey(for: book, isCover: isCover)
    return cache.object(forKey: key as NSString)
  }

  private func cacheImage(_ image: UIImage, for book: TPPBook, isCover: Bool) {
    let key = cacheKey(for: book, isCover: isCover)
    let estimatedSize = Int(image.size.width * image.size.height * 4)
    cache.setObject(image, forKey: key as NSString, cost: estimatedSize)
  }

  private func fetchImage(from url: URL, completion: @escaping (_ image: UIImage?) -> Void) {
    requestsLock.lock()

    if var handlers = inProgressRequests[url] {
      handlers.append(completion)
      inProgressRequests[url] = handlers
      requestsLock.unlock()
      return
    }

    inProgressRequests[url] = [completion]
    requestsLock.unlock()

    urlSession.dataTask(with: url) { [weak self] data, _, error in
      guard let self = self else {
        self?.completeAllRequests(for: url, with: nil)
        return
      }

      if let error = error {
        ATLog(.error, "Failed to load image from \(url): \(error.localizedDescription)")
        self.completeAllRequests(for: url, with: nil)
        return
      }

      guard let data = data else {
        ATLog(.error, "Received empty data from \(url)")
        self.completeAllRequests(for: url, with: nil)
        return
      }

      DispatchQueue.global(qos: .userInitiated).async {
        guard let image = UIImage(data: data) else {
          ATLog(.error, "Invalid image data from \(url)")
          self.completeAllRequests(for: url, with: nil)
          return
        }
        
        let decompressed = self.decompressImage(image)
        self.completeAllRequests(for: url, with: decompressed)
      }
    }.resume()
  }

  private func completeAllRequests(for url: URL, with image: UIImage?) {
    requestsLock.lock()
    guard let handlers = inProgressRequests[url] else {
      requestsLock.unlock()
      return
    }

    inProgressRequests.removeValue(forKey: url)
    requestsLock.unlock()

    DispatchQueue.main.async {
      for handler in handlers {
        handler(image)
      }
    }
  }

  private func cancelImageDownload(for url: URL) {
    requestsLock.lock()
    inProgressRequests.removeValue(forKey: url)
    requestsLock.unlock()
  }

  private func decompressImage(_ image: UIImage) -> UIImage {
    let pixelCount = image.size.width * image.size.height
    if pixelCount < (200 * 200) { return image }

    let maxDim: CGFloat = 2048
    var targetSize = image.size
    if targetSize.width > maxDim || targetSize.height > maxDim {
      let aspect = targetSize.width / targetSize.height
      if aspect > 1 {
        targetSize.width  = maxDim
        targetSize.height = maxDim / aspect
      } else {
        targetSize.width  = maxDim * aspect
        targetSize.height = maxDim
      }
    }

    let format = UIGraphicsImageRendererFormat()
    format.scale = image.scale
    let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
    return renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: targetSize))
    }
  }

  private func generateBookCoverImage(_ book: TPPBook) -> UIImage? {
    let width: CGFloat = 80
    let height: CGFloat = 120

    func makeCover() -> UIImage? {
      let coverView = NYPLTenPrintCoverView(
        frame: CGRect(x: 0, y: 0, width: width, height: height),
        withTitle: book.title,
        withAuthor: book.authors ?? "Unknown Author",
        withScale: 0.4
      )

      UIGraphicsBeginImageContextWithOptions(CGSize(width: width, height: height), true, 0)
      defer { UIGraphicsEndImageContext() }

      guard let ctx = UIGraphicsGetCurrentContext(), let cv = coverView else {
        return nil
      }
      cv.layer.render(in: ctx)
      return UIGraphicsGetImageFromCurrentImageContext()
    }

    if Thread.isMainThread {
      return makeCover()
    }

    var image: UIImage?
    DispatchQueue.main.sync {
      image = makeCover()
    }
    return image
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
    cacheQueue.async {
      guard let imagesDir = self.imagesDirectoryURL else { return }

      do {
        let fileURLs = try self.fileManager.contentsOfDirectory(at: imagesDir, includingPropertiesForKeys: [.contentModificationDateKey])

        let expirationDate = Date().addingTimeInterval(-7 * 24 * 60 * 60)

        for fileURL in fileURLs {
          do {
            let attributes = try self.fileManager.attributesOfItem(atPath: fileURL.path)
            if let modificationDate = attributes[.modificationDate] as? Date, modificationDate < expirationDate {
              try self.fileManager.removeItem(at: fileURL)
              ATLog(.info, "Deleted old image: \(fileURL.lastPathComponent)")
            }
          } catch {
            ATLog(.error, "Failed to check or delete image: \(error.localizedDescription)")
          }
        }
      } catch {
        ATLog(.error, "Failed to clean up old images: \(error.localizedDescription)")
      }
    }
  }

  @objc private func clearMemoryCache() {
    cache.removeAllObjects()

    requestsLock.lock()
    inProgressRequests.removeAll()
    requestsLock.unlock()
  }
}
