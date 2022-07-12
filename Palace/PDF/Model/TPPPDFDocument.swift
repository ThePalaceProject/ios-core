//
//  TPPPDFDocument.swift
//  Palace
//
//  Created by Vladimir Fedorov on 17.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import PDFKit

@objcMembers class TPPPDFDocument: NSObject {
  let data: Data
  let decryptor: ((_ data: Data, _ start: UInt, _ end: UInt) -> Data)?
  let isEncrypted: Bool
  
  init(data: Data) {
    self.data = data
    self.decryptor = nil
    self.isEncrypted = false
  }
  
  init(encryptedData: Data, decryptor: @escaping (_ data: Data, _ start: UInt, _ end: UInt) -> Data) {
    self.data = encryptedData
    self.decryptor = decryptor
    self.isEncrypted = true
  }
  
  lazy var encryptedDocument: TPPEncryptedPDFDocument? = {
    guard let decryptor = decryptor, isEncrypted else {
      return nil
    }
    return TPPEncryptedPDFDocument(encryptedData: data, decryptor: decryptor)
  }()
  
  lazy var document: PDFDocument? = {
    guard !isEncrypted else {
      return nil
    }
    return PDFDocument(data: data)
  }()

  var tableOfContents: [TPPPDFLocation] {
    document?.tableOfContents.map { TPPPDFLocation(title: $0.title, subtitle: nil, pageValue: nil, pageNumber: $0.pageNumber) } ?? []
  }
 
}


extension TPPPDFDocument {
  
  var title: String? {
    isEncrypted ? encryptedDocument?.title : document?.title
  }
  
  func decrypt(data: Data, start: UInt, end: UInt) -> Data {
    decryptor?(data, start, end) ?? data
  }

  var pageCount: Int {
    (isEncrypted ? encryptedDocument?.pageCount : document?.pageCount) ?? 0
  }
  
  func preview(for page: Int) -> UIImage? {
    image(page: page, size: .pdfPreviewSize)
  }

  func thumbnail(for page: Int) -> UIImage? {
    isEncrypted ?
    encryptedDocument?.thumbnail(for: page) :
    image(page: page, size: .pdfThumbnailSize)
  }

  func image(page: Int, size: CGSize) -> UIImage? {
    isEncrypted ?
    encryptedDocument?.page(at: page)?.image(of: size, for: .mediaBox) :
    document?.page(at: page)?.thumbnail(of: size, for: .mediaBox)
  }
  
  func search(text: String) -> [TPPPDFLocation] {
    return []
  }

}
