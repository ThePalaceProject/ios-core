//
//  TPPEncryptedPDFDocument.swift
//  Palace
//
//  Created by Vladimir Fedorov on 20.05.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import UIKit

// MARK: - TPPEncryptedPDFDocument

/// Encrypted PDF document.
@objcMembers class TPPEncryptedPDFDocument: NSObject {
  private var thumbnailsCache = NSCache<NSNumber, NSData>()

  /// PDF document data.
  let data: Data
  /// Decryptor for document data.
  let decryptor: (_ data: Data, _ start: UInt, _ end: UInt) -> Data

  /// PDF document.
  var document: CGPDFDocument?

  var pageCount: Int = 0
  var title: String?
  var cover: UIImage?

  init(encryptedData: Data, decryptor: @escaping (_ data: Data, _ start: UInt, _ end: UInt) -> Data) {
    data = encryptedData
    self.decryptor = decryptor
    let pdfDataProvider = TPPEncryptedPDFDataProvider(data: encryptedData, decryptor: decryptor)
    let dataProvider = pdfDataProvider.dataProvider().takeUnretainedValue()
    document = CGPDFDocument(dataProvider)
    super.init()

    setPageCount()
    setTitle()
    setCover()
  }

  func setPageCount() {
    Task {
      self.pageCount = (try? await document?.pageCount() ?? 0) ?? 0
    }
  }

  func setTitle() {
    Task {
      self.title = try? await document?.title() ?? ""
    }
  }

  func setCover() {
    Task {
      self.cover = try? await document?.cover() ?? UIImage()
    }
  }

  func page(at n: Int) -> CGPDFPage? {
    // Bookmarks compatibility:
    // CGPDFDocument counts pages from 1; PDFDocument from 0
    document?.page(at: n + 1)
  }

  func makeThumbnails() {
    Task {
      DispatchQueue.pdfThumbnailRenderingQueue.async {
        for page in 0..<self.pageCount {
          let pageNumber = NSNumber(value: page)
          if self.thumbnailsCache.object(forKey: pageNumber) != nil {
            continue
          }
          if let thumbnail = self.thumbnail(for: page),
             let thumbnailData = thumbnail.jpegData(compressionQuality: 0.5)
          {
            DispatchQueue.main.async {
              self.thumbnailsCache.setObject(thumbnailData as NSData, forKey: pageNumber)
            }
          }
        }
      }
    }
  }

  var tableOfContents: [TPPPDFLocation] = []

  func search(text: String) async -> [TPPPDFLocation] {
    guard let document else {
      return []
    }

    let searchText = text.lowercased()
    var result = [TPPPDFLocation]()
    for pageNumber in 1...pageCount {
      guard let page = document.page(at: pageNumber) else {
        continue
      }
      let extractor = TPPPDFTextExtractor()
      let textBlocks = extractor.extractText(page: page)
      let lowercaseBlocks = textBlocks.map { $0.lowercased() }
      for (i, textBlock) in lowercaseBlocks.enumerated() {
        if textBlock.contains(searchText) {
          // ! CGPDF first page index is 1, that's why we subtract 1 from pageNumber
          result.append(TPPPDFLocation(
            title: textBlocks[i],
            subtitle: nil,
            pageLabel: nil,
            pageNumber: page.pageNumber - 1
          ))
        }
      }
    }
    return result
  }
}

extension TPPEncryptedPDFDocument {
  func encryptedData() -> Data {
    data
  }

  func decrypt(data: Data, start: UInt, end: UInt) -> Data {
    decryptor(data, start, end)
  }
}

extension TPPEncryptedPDFDocument {
  /// Preview image for a page
  /// - Parameter page: Page number
  /// - Returns: Rendered page image
  ///
  /// `preview` returns a larger image than `thumbnail`
  func preview(for page: Int) -> UIImage? {
    self.page(at: page)?.preview
  }

  /// Thumbnail image for a page
  /// - Parameter page: Page number
  /// - Returns: Rendered page image
  ///
  /// `thumbnail` returns a smaller image than `preview`
  ///
  /// This function caches thumbnail image data and returnes a cached image when one is available.
  func thumbnail(for page: Int) -> UIImage? {
    let pageNumber = NSNumber(value: page)
    if let cachedData = thumbnailsCache.object(forKey: pageNumber),
       let cachedImage = UIImage(data: cachedData as Data)
    {
      return cachedImage
    } else {
      if let image = self.page(at: page)?.thumbnail, let data = image.jpegData(compressionQuality: 0.5) {
        thumbnailsCache.setObject(data as NSData, forKey: pageNumber)
        return image
      } else {
        return nil
      }
    }
  }

  /// Cached thumbnail image for a page
  /// - Parameter page: Page number
  /// - Returns: Thumbnail image, if it is available in cached images, `nil` otherwise.
  ///
  /// This function doesn't render new thumbnail images.
  func cachedThumbnail(for page: Int) -> UIImage? {
    let pageNumber = NSNumber(value: page)
    if let cachedData = thumbnailsCache.object(forKey: pageNumber),
       let cachedImage = UIImage(data: cachedData as Data)
    {
      return cachedImage
    }
    return nil
  }

  /// Image for a page
  /// - Parameters:
  ///   - page: Page number
  ///   - size: Size of the image to render
  /// - Returns: Rendered page image
  func image(for page: Int, size: CGSize?) -> UIImage? {
    self.page(at: page)?.image(of: size)
  }
}

extension TPPEncryptedPDFDocument {
  /// `TPPEncryptedPDFDocument` for SwiftUI previews
  static var preview: TPPEncryptedPDFDocument {
    TPPEncryptedPDFDocument(encryptedData: Data()) { data, _, _ in
      data
    }
  }
}
