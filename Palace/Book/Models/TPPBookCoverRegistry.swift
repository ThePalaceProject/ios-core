//
//  TPPBookCoverRegistry.swift
//  Palace
//
//  Created by Vladimir Fedorov on 26.10.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import UIKit

class TPPBookCoverRegistry {

  // MARK: - Properties

  private let inMemoryCache: NSCache<NSString, UIImage> = {
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

  // MARK: - Public Methods

  @MainActor
  func thumbnailImageForBook(_ book: TPPBook, handler: @escaping (_ image: UIImage?) -> Void) {
    if let cachedImage = getCachedImage(forKey: book.identifier) {
      handler(cachedImage)
      return
    }

    if let localImage = loadImageFromDisk(for: book) {
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
        self.cacheImage(finalImage, forKey: book.identifier)
        self.saveImageToDisk(finalImage, for: book)
      }
      handler(finalImage)
    }
  }

  @MainActor
  func coverImageForBook(_ book: TPPBook, handler: @escaping (_ image: UIImage?) -> Void) {
    thumbnailImageForBook(book) { [weak self] thumbnail in
      guard let self = self else { return }
      handler(thumbnail)

      guard let imageUrl = book.imageURL else { return }

      self.fetchImage(from: imageUrl) { image in
        if let image = image {
          DispatchQueue.main.async {
            handler(image)
          }
        }
      }
    }
  }

  actor ResultAggregator {
    private var result: [String: UIImage] = [:]

    func add(_ key: String, image: UIImage) {
      result[key] = image
    }

    func getResult() -> [String: UIImage] {
      return result
    }
  }

  @MainActor
  func thumbnailImagesForBooks(_ books: Set<TPPBook>, handler: @escaping (_ bookIdentifiersToImages: [String: UIImage]) -> Void) {
    let resultAggregator = ResultAggregator()
    let dispatchGroup = DispatchGroup()

    for book in books {
      dispatchGroup.enter()
      thumbnailImageForBook(book) { image in
        if let image = image {
          Task {
            await resultAggregator.add(book.identifier, image: image)
          }
        }
        dispatchGroup.leave()
      }
    }

    dispatchGroup.notify(queue: .main) {
      Task {
        let finalResult = await resultAggregator.getResult()
        handler(finalResult)
      }
    }
  }
  @discardableResult
  func cachedThumbnailImageForBook(_ book: TPPBook) -> UIImage? {
    return getCachedImage(forKey: book.identifier)
  }

  // MARK: - Private Methods

  private func getCachedImage(forKey key: String) -> UIImage? {
    cacheQueue.sync {
      return inMemoryCache.object(forKey: key as NSString)
    }
  }

  private func cacheImage(_ image: UIImage, forKey key: String) {
    cacheQueue.async(flags: .barrier) {
      self.inMemoryCache.setObject(image, forKey: key as NSString)
    }
  }

  private func loadImageFromDisk(for book: TPPBook) -> UIImage? {
    guard let imagePath = pinnedThumbnailImageUrlOfBookIdentifier(book.identifier)?.path,
          FileManager.default.fileExists(atPath: imagePath) else {
      return nil
    }
    return UIImage(contentsOfFile: imagePath)
  }

  private func saveImageToDisk(_ image: UIImage, for book: TPPBook) {
    guard let fileUrl = pinnedThumbnailImageUrlOfBookIdentifier(book.identifier),
          let data = image.pngData() else { return }

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
      guard let data = data, let image = UIImage(data: data) else {
        ATLog(.error, "Failed to load image from \(url): \(error?.localizedDescription ?? "Unknown error")")
        completion(nil)
        return
      }
      completion(image)
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

  private func pinnedThumbnailImageUrlOfBookIdentifier(_ bookIdentifier: String) -> URL? {
    return pinnedThumbnailImageDirectoryURL?.appendingPathComponent(bookIdentifier.sha256())
  }

  private var pinnedThumbnailImageDirectoryURL: URL? {
    guard let accountsDirectoryUrl = TPPBookContentMetadataFilesHelper.currentAccountDirectory() else {
      return nil
    }
    let pinnedThumbnailsFolderUrl = accountsDirectoryUrl.appendingPathComponent("pinned-thumbnail-images")
    try? FileManager.default.createDirectory(at: pinnedThumbnailsFolderUrl, withIntermediateDirectories: true)
    return pinnedThumbnailsFolderUrl
  }
}
