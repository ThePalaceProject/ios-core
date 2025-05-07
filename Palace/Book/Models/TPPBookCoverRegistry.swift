import Foundation
import UIKit

class TPPBookCoverRegistry {

  // MARK: - Shared Instance
  static let shared = TPPBookCoverRegistry()

  // MARK: - Cache Toggle based on Device Memory
  private let isCachingEnabled: Bool = {
    ProcessInfo.processInfo.physicalMemory >= 2 * 1024 * 1024 * 1024
  }()

  // MARK: - Caches & Queues
  private let memoryCache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 100
    cache.totalCostLimit = 10 * 1024 * 1024
    return cache
  }()

  private let diskCacheURL: URL? = {
    let fm = FileManager.default
    guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
      return nil
    }
    let dir = caches.appendingPathComponent("TPPBookCovers", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }()

  private let syncQueue = DispatchQueue(label: "com.thepalaceproject.TPPBookCoverRegistry.syncQueue", attributes: .concurrent)
  private let diskQueue = DispatchQueue(label: "com.thepalaceproject.TPPBookCoverRegistry.diskQueue")

  private let downloadQueue: OperationQueue = {
    let q = OperationQueue()
    q.name = "com.thepalaceproject.TPPBookCoverRegistry.downloadQueue"
    q.maxConcurrentOperationCount = 4
    return q
  }()

  private let decodeQueue: OperationQueue = {
    let q = OperationQueue()
    q.name = "com.thepalaceproject.TPPBookCoverRegistry.decodeQueue"
    q.maxConcurrentOperationCount = 2
    return q
  }()

  private var inProgressRequests: [URL: [(UIImage?) -> Void]] = [:]

  // MARK: - Initialization
  init() {
    NotificationCenter.default.addObserver(self,
                                           selector: #selector(clearMemoryCache),
                                           name: UIApplication.didReceiveMemoryWarningNotification,
                                           object: nil)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Public API

  func thumbnailImageForBook(_ book: TPPBook, handler: @escaping (UIImage?) -> Void) {
    let key = cacheKey(for: book, isCover: false)

    if isCachingEnabled, let img = memoryCache.object(forKey: key as NSString) {
      DispatchQueue.main.async { handler(img) }
      return
    }

    if isCachingEnabled, let diskURL = imageFileURL(for: book, isCover: false) {
      diskQueue.async {
        if let data = try? Data(contentsOf: diskURL), let img = UIImage(data: data) {
          let cost = Int(img.size.width * img.size.height * 4)
          self.memoryCache.setObject(img, forKey: key as NSString, cost: cost)
          DispatchQueue.main.async { handler(img) }
          return
        }
        self.fetchCoverImage(from: book.imageThumbnailURL, book: book, isCover: false, handler: handler)
      }
    } else {
      fetchCoverImage(from: book.imageThumbnailURL, book: book, isCover: false, handler: handler)
    }
  }

  func coverImageForBook(_ book: TPPBook, handler: @escaping (UIImage?) -> Void) {
    guard let url = book.imageURL else {
      thumbnailImageForBook(book, handler: handler)
      return
    }
    let key = cacheKey(for: book, isCover: true)

    if isCachingEnabled, let img = memoryCache.object(forKey: key as NSString) {
      DispatchQueue.main.async { handler(img) }
      return
    }

    if isCachingEnabled, let diskURL = imageFileURL(for: book, isCover: true) {
      diskQueue.async {
        if let data = try? Data(contentsOf: diskURL), let img = UIImage(data: data) {
          let cost = Int(img.size.width * img.size.height * 4)
          self.memoryCache.setObject(img, forKey: key as NSString, cost: cost)
          DispatchQueue.main.async { handler(img) }
          return
        }
        self.fetchCoverImage(from: url, book: book, isCover: true, handler: handler)
      }
    } else {
      fetchCoverImage(from: url, book: book, isCover: true, handler: handler)
    }
  }

  @MainActor
  func thumbnailImagesForBooks(_ books: Set<TPPBook>, handler: @escaping ([String: UIImage]) -> Void) {
    var result: [String: UIImage] = [:]
    let total = books.count
    var completed = 0
    books.forEach { book in
      thumbnailImageForBook(book) { image in
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

  func cancelImageDownloadsForBook(_ book: TPPBook) {
    if let url = book.imageThumbnailURL { cancelRequest(for: url) }
    if let url = book.imageURL { cancelRequest(for: url) }
  }

  @discardableResult
  func cachedThumbnailImageForBook(_ book: TPPBook) -> UIImage? {
    guard isCachingEnabled else { return nil }
    let key = cacheKey(for: book, isCover: false)
    return memoryCache.object(forKey: key as NSString)
  }

  // MARK: - Private Helpers

  private func fetchCoverImage(from urlOpt: URL?, book: TPPBook, isCover: Bool, handler: @escaping (UIImage?) -> Void) {
    guard let url = urlOpt else {
      let placeholder = generateBookCoverImage(book)
      DispatchQueue.main.async { handler(placeholder) }
      return
    }

    syncQueue.sync {
      if var handlers = inProgressRequests[url] {
        handlers.append(handler)
        inProgressRequests[url] = handlers
        return
      }
      inProgressRequests[url] = [handler]
      downloadQueue.addOperation { [weak self] in
        guard let self = self else { return }
        let task = URLSession.shared.dataTask(with: url) { data, _, error in
          if let data = data {
            self.decodeQueue.addOperation {
              let img = UIImage(data: data)
              if let image = img {
                self.store(image: image, for: book, isCover: isCover)
              }
              self.complete(url: url, image: img)
            }
          } else {
            self.complete(url: url, image: nil)
          }
        }
        task.resume()
      }
    }
  }

  private func complete(url: URL, image: UIImage?) {
    var handlers: [(UIImage?) -> Void] = []
    syncQueue.sync(flags: .barrier) {
      handlers = inProgressRequests[url] ?? []
      inProgressRequests.removeValue(forKey: url)
    }
    DispatchQueue.main.async {
      handlers.forEach { $0(image) }
    }
  }

  private func cancelRequest(for url: URL) {
    syncQueue.sync(flags: .barrier) {
      inProgressRequests.removeValue(forKey: url)
    }
  }

  private func store(image: UIImage, for book: TPPBook, isCover: Bool) {
    guard isCachingEnabled else { return }
    let key = cacheKey(for: book, isCover: isCover)
    let cost = Int(image.size.width * image.size.height * 4)
    memoryCache.setObject(image, forKey: key as NSString, cost: cost)
    
    if let diskDir = diskCacheURL,
       let data = image.jpegData(compressionQuality: 0.8) {
      let fileURL = diskDir.appendingPathComponent(key)
      diskQueue.async {
        try? data.write(to: fileURL)
      }
    }
  }

  private func generateBookCoverImage(_ book: TPPBook) -> UIImage? {
    // Ensure UI code runs on main thread
    if !Thread.isMainThread {
      return DispatchQueue.main.sync {
        self.generateBookCoverImage(book)
      }
    }
    let width: CGFloat = 80
    let height: CGFloat = 120
    let format = UIGraphicsImageRendererFormat()
    format.scale = UIScreen.main.scale
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
    return renderer.image { context in
      if let coverView = NYPLTenPrintCoverView(
        frame: CGRect(x: 0, y: 0, width: width, height: height),
        withTitle: book.title,
        withAuthor: book.authors ?? "Unknown Author",
        withScale: 0.4
      ) {
        coverView.layer.render(in: context.cgContext)
      }
    }
  }

  private func cacheKey(for book: TPPBook, isCover: Bool) -> String {
    "\(book.identifier)_\(isCover ? "cover" : "thumbnail")"
  }

  private func imageFileURL(for book: TPPBook, isCover: Bool) -> URL? {
    guard let dir = diskCacheURL else { return nil }
    let filename = cacheKey(for: book, isCover: isCover)
    return dir.appendingPathComponent(filename)
  }

  @objc private func clearMemoryCache() {
    memoryCache.removeAllObjects()
  }
}
