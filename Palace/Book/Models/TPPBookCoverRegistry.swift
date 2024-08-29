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
  
  private lazy var inMemoryCache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 100 // Adjust based on memory constraints
    return cache
  }()
  
  func thumbnailImageForBook(_ book: TPPBook, handler: @escaping (_ image: UIImage?) -> Void) {
    if let cachedImage = inMemoryCache.object(forKey: book.identifier as NSString) {
      handler(cachedImage)
      return
    }
    
    if let imagePath = pinnedThumbnailImageUrlOfBookIdentifier(book.identifier)?.path, FileManager.default.fileExists(atPath: imagePath) {
      if let image = UIImage(contentsOfFile: imagePath) {
        inMemoryCache.setObject(image, forKey: book.identifier as NSString)
        handler(image)
        return
      }
    }
    
    guard let thumbnailUrl = book.imageThumbnailURL else {
      handler(generateBookCoverImage(book))
      return
    }
    
    fetchImage(from: thumbnailUrl, for: book) { [weak self] image in
      guard let self = self else { return }
      if let image = image {
        self.inMemoryCache.setObject(image, forKey: book.identifier as NSString)
        self.pinThumbnailImage(image, for: book)
        handler(image)
      } else {
        handler(self.generateBookCoverImage(book))
      }
    }
  }
  
  func coverImageForBook(_ book: TPPBook, handler: @escaping (_ image: UIImage?) -> Void) {
    thumbnailImageForBook(book, handler: handler)
    guard let imageUrl = book.imageURL else { return }
    
    fetchImage(from: imageUrl, for: book) { image in
      if let image = image {
        DispatchQueue.main.async {
          handler(image)
        }
      }
    }
  }
  
  func thumbnailImagesForBooks(_ books: Set<TPPBook>, handler: @escaping (_ bookIdentifiersToImages: [String: UIImage]) -> Void) {
    var result: [String: UIImage] = [:]
    let dispatchGroup = DispatchGroup()
    
    books.forEach { book in
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
  
  @discardableResult func cachedThumbnailImageForBook(_ book: TPPBook) -> UIImage? {
    return inMemoryCache.object(forKey: book.identifier as NSString)
  }
  
  private func fetchImage(from url: URL, for book: TPPBook, completion: @escaping (_ image: UIImage?) -> Void) {
    let request = URLRequest(url: url, applyingCustomUserAgent: true)
    urlSession.dataTask(with: request) { data, response, error in
      guard let data = data, let image = UIImage(data: data) else {
        completion(nil)
        return
      }
      DispatchQueue.main.async {
        completion(image)
      }
    }.resume()
  }
  
  private func pinThumbnailImage(_ image: UIImage, for book: TPPBook) {
    guard let fileUrl = pinnedThumbnailImageUrlOfBookIdentifier(book.identifier) else { return }
    if let data = image.pngData() {
      try? data.write(to: fileUrl, options: .atomic)
    }
  }
  
  private func generateBookCoverImage(_ book: TPPBook) -> UIImage? {
    var image: UIImage?
    let width: CGFloat = 80
    let height: CGFloat = 120
    DispatchQueue.main.async {
      let coverView = NYPLTenPrintCoverView(frame: CGRect(x: 0, y: 0, width: width, height: height), withTitle: book.title, withAuthor: book.authors, withScale: 0.4)
      UIGraphicsBeginImageContextWithOptions(CGSize(width: width, height: height), true, 0)
      if let context = UIGraphicsGetCurrentContext() {
        coverView?.layer.render(in: context)
        image = UIGraphicsGetImageFromCurrentImageContext()
      }
      UIGraphicsEndImageContext()
    }
    return image
  }
  
  private lazy var urlSession: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.httpCookieStorage = nil
    configuration.httpMaximumConnectionsPerHost = 8
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 30
    configuration.urlCache?.diskCapacity = 16 * 1024 * 1024
    configuration.urlCache?.memoryCapacity = 2 * 1024 * 1024
    configuration.urlCredentialStorage = nil
    
    return URLSession(configuration: configuration)
  }()
  
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
