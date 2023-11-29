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
    // CGPDFDocument counts pages from 1; PDFDocument from 0
    document?.page(at: n + 1)
  }
  
  func makeThumbnails() {
    let pageCount = self.document?.pageCount ?? 0
    DispatchQueue.pdfThumbnailRenderingQueue.async {
      for page in 0..<pageCount {
        let pageNumber = NSNumber(value: page)
        if self.thumbnailsCache.object(forKey: pageNumber) != nil {
          continue
        }
        if let thumbnail = self.thumbnail(for: page), let thumbnailData = thumbnail.jpegData(compressionQuality: 0.5) {
          DispatchQueue.main.async {
            self.thumbnailsCache.setObject(thumbnailData as NSData, forKey: pageNumber)
          }
        }
      }
    }
  }
  
  var tableOfContents: [TPPPDFLocation] = []
  
  func search(text: String) -> [TPPPDFLocation] {
    guard let document else {
      return []
    }
    let searchText = text.lowercased()
    var result = [TPPPDFLocation]()
    for pageNumber in 1...pageCount {
      guard let page = document.page(at: pageNumber) else {
        continue
      }
      let parser = TPPPDFParser()
      let textBlocks = parser.extractText(page: page).map { $0.lowercased() }
      for textBlock in textBlocks {
        if textBlock.contains(text) {
          // ! CGPDF first page index is 1, that's why we subtract 1 from pageNumber
          result.append(TPPPDFLocation(title: textBlock, subtitle: nil, pageLabel: nil, pageNumber: page.pageNumber - 1))
        }
      }
    }
    return result
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
  
  /// Cached thumbnail image for a page
  /// - Parameter page: Page number
  /// - Returns: Thumbnail image, if it is available in cached images, `nil` otherwise.
  ///
  /// This function doesn't render new thumbnail images.
  func cachedThumbnail(for page: Int) -> UIImage? {
    let pageNumber = NSNumber(value: page)
    if let cachedData = thumbnailsCache.object(forKey: pageNumber), let cachedImage = UIImage(data: cachedData as Data) {
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
    TPPEncryptedPDFDocument(encryptedData: Data()) { data, start, end in
      data
    }
  }
}

// MARK: - PDF Page parser

fileprivate class TPPPDFParser {
  private var textBlocks = [String]()
  // Extracts blocks of text
  // One block is not neccessarily a sentences, a line of text, or even one word -
  // depending on the software used, it can contain one-two letters only.
  func extractText(page: CGPDFPage) -> [String] {
    let stream = CGPDFContentStreamCreateWithPage(page)
    let operatorTable = CGPDFOperatorTableCreate()
    // Documentation:
    // https://developer.apple.com/documentation/coregraphics/1454118-cgpdfoperatortablesetcallback
    // PDF operators:
    // https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/pdfreference1.3.pdf
    // "TJ" operator: an array of blocks (strings, numbers, etc)
    CGPDFOperatorTableSetCallback(operatorTable!, "TJ") { scanner, context in
      guard let context = context else { return }
      let extractor = Unmanaged<TPPPDFParser>.fromOpaque(context).takeUnretainedValue()
      extractor.handleArray(scanner: scanner)
    }
    // String operators
    for op in ["Tj", "\"", "'"] {
      CGPDFOperatorTableSetCallback(operatorTable!, op) { scanner, context in
        guard let context = context else { return }
        let extractor = Unmanaged<TPPPDFParser>.fromOpaque(context).takeUnretainedValue()
        extractor.handleString(scanner: scanner)
      }
    }
    let scanner = CGPDFScannerCreate(stream, operatorTable, Unmanaged.passUnretained(self).toOpaque())
    CGPDFScannerScan(scanner)
    return textBlocks
  }
  
  /// String operator handler
  /// - Parameter scanner: `CGPDFScannerRef`
  private func handleString(scanner: CGPDFScannerRef) {
    var pdfString: CGPDFStringRef?
    if CGPDFScannerPopString(scanner, &pdfString), let pdfString, let cfString = CGPDFStringCopyTextString(pdfString) {
      let string = cfString as String
      // Skip control sequences
      if !string[string.startIndex].isWhitespace {
        textBlocks.append(string)
      }
    }
  }
  
  /// Array operator handler
  /// - Parameter scanner: `CGPDFScannerRef`
  private func handleArray(scanner: CGPDFScannerRef) {
    var array: CGPDFArrayRef?
    guard CGPDFScannerPopArray(scanner, &array), let array else { return }
    
    var blockValue = ""
    // Iterate through the array elements
    let count = CGPDFArrayGetCount(array)
    for index in 0..<count {
      var obj: CGPDFObjectRef?
      guard CGPDFArrayGetObject(array, index, &obj), let obj else { continue }
      
      let type = CGPDFObjectGetType(obj)
      switch type {
      case .string:
        // Extract and append the string to the text
        var pdfString: CGPDFStringRef?
        if CGPDFObjectGetValue(obj, .string, &pdfString), let pdfString, let cfString = CGPDFStringCopyTextString(pdfString) {
          let string = cfString as String
          // Skip control sequences
          if !string[string.startIndex].isWhitespace {
            print(">> \(string)")
            blockValue += string
          }
        }
      case .real:
        var realValue: CGPDFReal = 0.0
        if CGPDFObjectGetValue(obj, .real, &realValue) {
          // Real values adjust the spacing between elements (e.g., letters).
          // "100" is an empirical value large enough to represent a space between words.
          // Text in PDFs can appear as a single line of characters without whitespace characters;
          // these values adjust the visual spacing between characters.
          if abs(realValue) > 100 {
            blockValue += " "
          }
        }
      case .integer:
        var intValue: CGPDFInteger = 0
        if CGPDFObjectGetValue(obj, .integer, &intValue) {
          // The same as realValue above
          if abs(intValue) > 100 {
            blockValue += " "
          }
        }
      default:
        break
      }
    }
    textBlocks.append(blockValue)
  }
}
