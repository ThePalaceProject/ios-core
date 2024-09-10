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
  
  func thumbnailImageForBook(_ book: TPPBook, handler: @escaping (_ image: UIImage?) -> Void) {
    if let cachedImage = inMemoryCache.object(forKey: book.identifier as NSString) {
      handler(cachedImage)
      return
    }
    
    if let imagePath = pinnedThumbnailImageUrlOfBookIdentifier(book.identifier)?.path, FileManager.default.fileExists(atPath: imagePath),
       let image = UIImage(contentsOfFile: imagePath) {
      inMemoryCache.setObject(image, forKey: book.identifier as NSString)
      handler(image)
      return
    }
    
    guard let thumbnailUrl = book.imageThumbnailURL else {
      handler(generateBookCoverImage(book))
      return
    }
    
    fetchImage(from: thumbnailUrl, for: book) { [weak self] image in
      guard let self = self, let image = image else {
        handler(self?.generateBookCoverImage(book))
        return
      }
      self.inMemoryCache.setObject(image, forKey: book.identifier as NSString)
      self.pinThumbnailImage(image, for: book)
      handler(image)
    }
  }
  
  func coverImageForBook(_ book: TPPBook, handler: @escaping (_ image: UIImage?) -> Void) {
    thumbnailImageForBook(book) { [weak self] thumbnail in
      guard let self = self else { return }
      handler(thumbnail)
      
      guard let imageUrl = book.imageURL else { return }
      
      self.fetchImage(from: imageUrl, for: book) { image in
        if let image = image {
          DispatchQueue.main.async {
            handler(image)
          }
        }
      }
    }
  }
  
  func thumbnailImagesForBooks(_ books: Set<TPPBook>, handler: @escaping (_ bookIdentifiersToImages: [String: UIImage]) -> Void) {
    var result = [String: UIImage]()
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
  
  @discardableResult
  func cachedThumbnailImageForBook(_ book: TPPBook) -> UIImage? {
    return inMemoryCache.object(forKey: book.identifier as NSString)
  }
  
  private func fetchImage(from url: URL, for book: TPPBook, completion: @escaping (_ image: UIImage?) -> Void) {
    let request = URLRequest(url: url, applyingCustomUserAgent: true)
    
    urlSession.dataTask(with: request) { data, response, error in
      guard let data = data else {
        // Handle error or return a placeholder image
        completion(nil)
        return
      }
      
      if let image = UIImage(data: data) {
        completion(image)
      } else {
        // Handle the failure to decode the image
        print("Failed to decode image data.")
        completion(nil) // or return a placeholder image
      }
    }.resume()
  }
  
  private func pinThumbnailImage(_ image: UIImage, for book: TPPBook) {
    guard let fileUrl = pinnedThumbnailImageUrlOfBookIdentifier(book.identifier) else { return }
    
    DispatchQueue.global(qos: .background).async {
      if let data = image.pngData() {
        try? data.write(to: fileUrl, options: .atomic)
      }
    }
  }
  
  private func generateBookCoverImage(_ book: TPPBook) -> UIImage? {
    let width: CGFloat = 80
    let height: CGFloat = 120
    let coverView = NYPLTenPrintCoverView(frame: CGRect(x: 0, y: 0, width: width, height: height), withTitle: book.title, withAuthor: book.authors, withScale: 0.4)
    
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
