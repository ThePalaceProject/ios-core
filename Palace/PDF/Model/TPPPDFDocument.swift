//
//  TPPPDFDocument.swift
//  Palace
//
//  Created by Vladimir Fedorov on 17.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import PDFKit

/// Wrapper class for PDF docuument in general
@objcMembers class TPPPDFDocument: NSObject {
  let data: Data
  let decryptor: ((_ data: Data, _ start: UInt, _ end: UInt) -> Data)?
  let isEncrypted: Bool
  
  /// Initialize with a non-encrypted document
  /// - Parameter data: PDF document data
  init(data: Data) {
    self.data = data
    self.decryptor = nil
    self.isEncrypted = false
  }
  
  /// Initialize with an encrypted PDF document data
  /// - Parameters:
  ///   - encryptedData: Encrypted PDF document data
  ///   - decryptor: Decryptor function
  init(encryptedData: Data, decryptor: @escaping (_ data: Data, _ start: UInt, _ end: UInt) -> Data) {
    self.data = encryptedData
    self.decryptor = decryptor
    self.isEncrypted = true
  }
  
  /// Encrypted PDF document
  lazy var encryptedDocument: TPPEncryptedPDFDocument? = {
    guard let decryptor = decryptor, isEncrypted else {
      return nil
    }
    return TPPEncryptedPDFDocument(encryptedData: data, decryptor: decryptor)
  }()
  
  /// PDFKit PDF document
  lazy var document: PDFDocument? = {
    guard !isEncrypted else {
      return nil
    }
    return PDFDocument(data: data)
  }()
}

// MARK: - Common properties of encrypted and non-encrypted PDF files

extension TPPPDFDocument {
  
  /// PDF title
  var title: String? {
    isEncrypted ? encryptedDocument?.title : document?.title
  }
  
  /// Decrypt PDF data
  /// - Parameters:
  ///   - data: Encrypted PDF data
  ///   - start: Start of the block of data to decrypt
  ///   - end: End of the block of data to decrypt
  /// - Returns: Decrypted block of data or original data if decryption was not possible
  func decrypt(data: Data, start: UInt, end: UInt) -> Data {
    decryptor?(data, start, end) ?? data
  }
  
  /// Number of pages in the PDF document
  var pageCount: Int {
    (isEncrypted ? encryptedDocument?.pageCount : document?.pageCount) ?? 0
  }
  
  /// Preview image for a page
  /// - Parameter page: Page number
  /// - Returns: Rendered page image
  ///
  /// `preview` returns a larger image than `thumbnail`
  func preview(for page: Int) -> UIImage? {
    image(page: page, size: .pdfPreviewSize)
  }

  /// Thumbnail image for a page
  /// - Parameter page: Page number
  /// - Returns: Rendered page image
  ///
  /// `thumbnail` returns a smaller image than `preview`
  func thumbnail(for page: Int) -> UIImage? {
    isEncrypted ?
    encryptedDocument?.thumbnail(for: page) :
    image(page: page, size: .pdfThumbnailSize)
  }
  
  /// Image for a page
  /// - Parameters:
  ///   - page: Page number
  ///   - size: Size of the image to render
  /// - Returns: Rendered page image
  func image(page: Int, size: CGSize) -> UIImage? {
    isEncrypted ?
    encryptedDocument?.page(at: page)?.image(of: size, for: .mediaBox) :
    document?.page(at: page)?.thumbnail(of: size, for: .mediaBox)
  }
  
  /// Search the document
  /// - Parameter text: Text string to look for
  /// - Returns: Array of PDF locations
  func search(text: String) -> [TPPPDFLocation] {
    // TODO: - Requires implementation
    return []
  }

  /// Table of contents for PDF document
  var tableOfContents: [TPPPDFLocation] {
    document?.tableOfContents.map { TPPPDFLocation(title: $0.title, subtitle: nil, pageValue: nil, pageNumber: $0.pageNumber) } ?? []
  }

}
