//
//  TPPEncryptedPDFDocument.swift
//  Palace
//
//  Created by Vladimir Fedorov on 20.05.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import UIKit

/// Encrypted PDF document.
@objcMembers class TPPEncryptedPDFDocument: NSObject {
  
  private var thumbnailsCache = NSCache<NSNumber, NSData>()
  
  /// PDF document data.
  let data: Data
  /// Decryptor for document data.
  let decryptor: (_ data: Data, _ start: UInt, _ end: UInt) -> Data
  
  /// PDF document.
  var document: CGPDFDocument?
    
  init(encryptedData: Data, decryptor: @escaping (_ data: Data, _ start: UInt, _ end: UInt) -> Data) {
    self.data = encryptedData
    self.decryptor = decryptor
    let pdfDataProvider = TPPEncryptedPDFDataProvider(data: encryptedData, decryptor: decryptor)
    let dataProvider = pdfDataProvider.dataProvider().takeUnretainedValue()
    self.document = CGPDFDocument(dataProvider)
    super.init()
    makeThumbnails()
  }
  
  var pageCount: Int {
    document?.pageCount ?? 0
  }
  
  var title: String? {
    document?.title
  }
  
  var cover: UIImage? {
    document?.cover
  }

  func page(at n: Int) -> CGPDFPage? {
    // Bookmarks compatibility:
    // CGPDFDocument counts pages from 1; PDDocument from 0
    document?.page(at: n + 1)
  }
  
  func makeThumbnails() {
    DispatchQueue.pdfThumbnailRenderingQueue.async {
      let pageCount = self.document?.pageCount ?? 0
      for page in 0..<pageCount {
        if let thumbnail = self.thumbnail(for: page), let thumbnailData = thumbnail.jpegData(compressionQuality: 0.5) {
          let pageNumber = NSNumber(value: page)
          DispatchQueue.main.async {
            self.thumbnailsCache.setObject(thumbnailData as NSData, forKey: pageNumber)
          }
        }
      }
    }
  }
  
  var tableOfContents: [TPPPDFLocation] = []

  func search(text: String) -> [TPPPDFLocation] {
    return []
  }
  
}

extension TPPEncryptedPDFDocument {
  func encryptedData() -> Data {
    self.data
  }
  func decrypt(data: Data, start: UInt, end: UInt) -> Data {
    return self.decryptor(data, start, end)
  }
}

extension TPPEncryptedPDFDocument {
  func preview(for page: Int) -> UIImage? {
    self.page(at: page)?.preview
  }

  func cachedThumbnail(for page: Int) -> UIImage? {
    let pageNumber = NSNumber(value: page)
    if let cachedData = thumbnailsCache.object(forKey: pageNumber), let cachedImage = UIImage(data: cachedData as Data) {
      return cachedImage
    }
    return nil
  }
  
  func thumbnail(for page: Int) -> UIImage? {
    let pageNumber = NSNumber(value: page)
    if let cachedData = thumbnailsCache.object(forKey: pageNumber), let cachedImage = UIImage(data: cachedData as Data) {
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
  func image(for page: Int, size: CGSize?) -> UIImage? {
    self.page(at: page)?.image(of: size)
  }
}

extension TPPEncryptedPDFDocument {
  /// `TPPEncryptedPDFDocument` for SwiftUI previews
  static var preview: TPPEncryptedPDFDocument {
    TPPEncryptedPDFDocument(encryptedData: Data()) { data, start, end in
      data
    }
  }
}
