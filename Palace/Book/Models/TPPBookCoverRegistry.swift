//
//  TPPBookCoverRegistry.swift
//  Palace
//
//  Created by Vladimir Fedorov on 26.10.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

class TPPBookCoverRegistry {
  
  /// Downloads or returns cached cover image for the provided book.
  /// - Parameters:
  ///   - book: `TPPBook` object.
  ///   - handler: completion handler.
  func thumbnailImageForBook(_ book: TPPBook, handler: @escaping (_ image: UIImage?) -> Void) {
    guard let imagePath = pinnedThumbnailImageUrlOfBookIdentifier(book.identifier)?.path else {
      handler(nil)
      return
    }
    let isPinned = TPPBookRegistry.shared.book(forIdentifier: book.identifier) != nil
    if isPinned {
      if let image = UIImage(contentsOfFile: imagePath) {
        handler(image)
      } else if let thumbnailUrl = book.imageThumbnailURL,
                let fileUrl = self.pinnedThumbnailImageUrlOfBookIdentifier(book.identifier) {
        self.getBookCoverImage(url: thumbnailUrl, fileUrl: fileUrl, handler: { [weak self] image in
          guard let self else { return }
          handler(image)
        }, forBook: book)
      }
    } else {
      if let thumbnailUrl = book.imageThumbnailURL {
        self.getBookCoverImage(url: thumbnailUrl, fileUrl: nil, handler: { [weak self] image in
          guard let self else { return }
          handler(image)
        }, forBook: book)
      } else {
        handler(self.generateBookCoverImage(book))
      }
    }
  }
  
  /// Downloads cover image for the provided book.
  /// - Parameters:
  ///   - book: `TPPBook` object.
  ///   - handler: completion handler.
  func coverImageForBook(_ book: TPPBook, handler: @escaping (_ image: UIImage?) -> Void) {
    thumbnailImageForBook(book, handler: handler)
    guard let imageUrl = book.imageURL else {
      return
    }
    var request = URLRequest(url: imageUrl)
    urlSession.dataTask(with: request.applyCustomUserAgent()) { imageData, response, error in
      if let imageData = imageData, let image = UIImage(data: imageData) {
        DispatchQueue.main.async {
          handler(image)
        }
      }
    }.resume()
  }
  
  /// Downloads or creates book covers for the provided set of books.
  /// - Parameters:
  ///   - books: A set of `TPPBook` objects.
  ///   - handler: completion handler. `handler()` is called once, after all covers are downloaded.
  func thumbnailImagesForBooks(_ books: Set<TPPBook>, handler: @escaping (_ bookIdentifiersToImages: [String: UIImage]) -> Void) {
    var result: [String: UIImage] = [:] {
      didSet {
        if books.count == result.keys.count {
          DispatchQueue.main.async {
            handler(result)
          }
        }
      }
    }
    books.forEach { book in
      guard let thumbnailUrl = book.imageThumbnailURL else {
        result[book.identifier] = self.generateBookCoverImage(book)
        return
      }
      
      urlSession.dataTask(with: URLRequest(url: thumbnailUrl, applyingCustomUserAgent: true)) { imageData, response, error in
        if let imageData = imageData, let image = UIImage(data: imageData) {
          DispatchQueue.main.async {
            result[book.identifier] = image
          }
        } else {
          DispatchQueue.main.async {
            result[book.identifier] = self.generateBookCoverImage(book)
          }
        }
      }.resume()
    }
  }
  
  /// Immediately returns the cached thumbnail if available, else nil. Generated images are not returned.
  /// - Parameter book: book
  /// - Returns: cover image, if one is available.
  func cachedThumbnailImageForBook(_ book: TPPBook) -> UIImage? {
    guard let thumbnailUrl = book.imageThumbnailURL,
          let cachedData = urlSession.configuration.urlCache?.cachedResponse(for: URLRequest(url: thumbnailUrl, applyingCustomUserAgent: true))?.data
    else {
      return nil
    }
    return UIImage(data: cachedData)
  }
  
  /// Saves cover image of the book.
  /// - Parameter book: `TPPBook` object.
  func pinThumbnailImageForBook(_ book: TPPBook) {
    guard let thumbnailUrl = book.imageThumbnailURL,
          let fileUrl = pinnedThumbnailImageUrlOfBookIdentifier(book.identifier)
    else {
      return
    }
    try? Data().write(to: fileUrl, options: .atomic)
    urlSession.dataTask(with: URLRequest(url: thumbnailUrl, applyingCustomUserAgent: true)) { imageData, response, error in
      if let imageData = imageData {
        do {
          try imageData.write(to: fileUrl, options: .atomic)
        } catch {
          Log.error(#file, "Error saving thumbnail file: \(error.localizedDescription)")
        }
      }
    }.resume()
  }
  
  /// Deletes cover image of a book with `bookIdentifier`.
  /// - Parameter bookIdentifier: book identifier.
  func removePinnedThumbnailImageForBookIdentifier(_ bookIdentifier: String) {
    guard let fileUrl = pinnedThumbnailImageUrlOfBookIdentifier(bookIdentifier) else {
      return
    }
    do {
      try FileManager.default.removeItem(at: fileUrl)
    } catch {
      Log.error(#file, "Error removeing thumbnail file: \(error.localizedDescription)")
    }
  }
  
  /// Deletes book cover directory
  func removeAllPinnedThumbnailImages() {
    do {
      if let url = pinnedThumbnailImageDirectoryURL {
        try FileManager.default.removeItem(at: url)
      }
    } catch {
      Log.error(#file, "Error removing thumbnail directory: \(error.localizedDescription)")
    }
  }
  
  private lazy var urlSession: URLSession = {
    let diskCacheInMegabytes = 16;
    let memoryCacheInMegabytes = 2;

    let configuration = URLSessionConfiguration.default
    configuration.httpCookieStorage = nil
    configuration.httpMaximumConnectionsPerHost = 8
    configuration.httpShouldUsePipelining = true
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 30
    configuration.urlCache?.diskCapacity = 1024 * 1024 * diskCacheInMegabytes
    configuration.urlCache?.memoryCapacity = 1024 * 1024 * memoryCacheInMegabytes
    configuration.urlCredentialStorage = nil
    
    return URLSession(configuration: configuration)
  }()
  
  /// Directory URL for pinned images
  private var pinnedThumbnailImageDirectoryURL: URL? {
    guard let accountsDirectoryUrl = TPPBookContentMetadataFilesHelper
      .currentAccountDirectory() else {
      Log.error(#file, "currentAccountDirectory is nil")
      return nil
    }
    do {
      let pinnedThumbnailsFolderUrl = accountsDirectoryUrl.appendingPathComponent("pinned-thumbnail-images")
      if !FileManager.default.fileExists(atPath: pinnedThumbnailsFolderUrl.path) {
        try FileManager.default.createDirectory(at: pinnedThumbnailsFolderUrl, withIntermediateDirectories: true)
      }
      return pinnedThumbnailsFolderUrl
    } catch {
      Log.error(#file, "Failed to create pinned thumbnail images folder.")
    }
    return nil
  }
  
  /// URL for pinned thumbnail image
  /// - Parameter bookIdentifier: book identifier
  /// - Returns: cover image file URL
  private func pinnedThumbnailImageUrlOfBookIdentifier(_ bookIdentifier: String) -> URL? {
    pinnedThumbnailImageDirectoryURL?.appendingPathComponent(bookIdentifier.sha256())
  }
  
  /// Downloads book cover image.
  /// - Parameters:
  ///   - url: cover image URL.
  ///   - fileUrl: file URL for storing the cover image.
  ///   - handler: completion handler.
  ///   - book: `TPPBook` object.
  private func getBookCoverImage(url: URL, fileUrl: URL?, handler:  @escaping (_ image: UIImage?) -> (), forBook book: TPPBook) {
    urlSession.dataTask(with: URLRequest(url: url, applyingCustomUserAgent: true)) { imageData, response, error in
      if let imageData = imageData, let image = UIImage(data: imageData) {
        DispatchQueue.main.async {
          handler(image)
          if let fileUrl = fileUrl {
            do {
              try imageData.write(to: fileUrl, options: .atomic)
            } catch {
              // log error
            }
          }
        }
      } else {
        DispatchQueue.main.async {
          handler(self.generateBookCoverImage(book))
        }
      }
    }.resume()
  }
  
  /// Generates TenPrintCover cover for books.
  /// - Parameter book: `TPPBook` object.
  /// - Returns: cover image
  private func generateBookCoverImage(_ book: TPPBook) -> UIImage? {
    var image: UIImage?
    let width: CGFloat = 80
    let height: CGFloat = 120
    let coverView = NYPLTenPrintCoverView(frame: CGRect(x: 0, y: 0, width: width, height: height), withTitle: book.title, withAuthor: book.authors, withScale: 0.4)
    UIGraphicsBeginImageContextWithOptions(CGSize(width: width, height: height), true, 0)
    if let context = UIGraphicsGetCurrentContext() {
      coverView?.layer.render(in: context)
      image = UIGraphicsGetImageFromCurrentImageContext()
    }
    UIGraphicsEndImageContext()
    return image
  }
}
