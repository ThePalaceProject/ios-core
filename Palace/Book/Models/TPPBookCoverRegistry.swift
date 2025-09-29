import Foundation
import UIKit

// MARK: - TPPBookCoverRegistry

actor TPPBookCoverRegistry {
  let imageCache: ImageCacheType

  static let shared = TPPBookCoverRegistry(imageCache: ImageCache.shared)

  private var inProgressTasks: [URL: Task<UIImage?, Never>] = [:]
  init(imageCache: ImageCacheType) {
    self.imageCache = imageCache
  }

  func coverImage(for book: TPPBook) async -> UIImage? {
    guard let url = book.imageURL else {
      return await thumbnailImage(for: book)
    }
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
    if let img = imageCache.get(for: key as String) {
      return img
    }

    if let existing = inProgressTasks[url] {
      return await existing.value
    }

    let task = Task<UIImage?, Never> { [weak self] in
      guard let self else {
        return UIImage()
      }

      do {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let image = UIImage(data: data) else {
          return nil
        }

        imageCache.set(image, for: key as String, expiresIn: nil)
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

// MARK: - TPPBookCoverRegistryBridge

@objcMembers
public class TPPBookCoverRegistryBridge: NSObject {
  public static let shared = TPPBookCoverRegistryBridge()

  /// Asynchronous, Objective-C friendly cover fetch
  /// - Parameters:
  ///   - book: The TPPBook instance
  ///   - completion: Block called on main thread with the UIImage or nil
  public func coverImageForBook(_ book: TPPBook, completion: @escaping (UIImage?) -> Void) {
    Task {
      let img = await TPPBookCoverRegistry.shared.coverImage(for: book)
      DispatchQueue.main.async {
        if let img = img {
          book.imageCache.set(img, for: book.identifier)
        }
        completion(img)
      }
    }
  }

  /// Asynchronous, Objective-C friendly thumbnail fetch
  public func thumbnailImageForBook(_ book: TPPBook, completion: @escaping (UIImage?) -> Void) {
    Task {
      let img = await TPPBookCoverRegistry.shared.thumbnailImage(for: book)
      DispatchQueue.main.async {
        if let img = img {
          book.imageCache.set(img, for: book.identifier)
        }
        completion(img)
      }
    }
  }
}
