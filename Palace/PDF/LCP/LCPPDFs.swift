//
//  LCPPDFs.swift
//  Palace
//
//  Created by Maurice Carrier on 3/22/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

#if LCP

import Foundation
import ReadiumShared
import ReadiumStreamer
import ReadiumLCP
import ZIPFoundation

/// LCP PDF helper class
@objc class LCPPDFs: NSObject {

  struct PDFManifest: Codable {
    struct ReadingOrderItem: Codable {
      let href: String
    }
    let readingOrder: [ReadingOrderItem]
  }

  private static let expectedAcquisitionType = "application/vnd.readium.lcp.license.v1.0+json"

  /// Check if the book is LCPPDF
  /// - Parameter book: pdf
  /// - Returns: `true` if the book is an LCP DRM protected PDF, `false` otherwise
  @objc static func canOpenBook(_ book: TPPBook) -> Bool {
    guard let defualtAcquisition = book.defaultAcquisition else { return false }
    return book.defaultBookContentType == .pdf && defualtAcquisition.type == expectedAcquisitionType
  }

  private let pdfUrl: URL
  private let assetRetriever: AssetRetriever
  private let publicationOpener: PublicationOpener
  let lcpService = LCPLibraryService()

  @objc init?(url: URL) {
    guard let contentProtection = lcpService.contentProtection else {
      TPPErrorLogger.logError(nil, summary: "Uninitialized contentProtection in LCPPDFs")
      return nil
    }
    self.pdfUrl = url

    let httpClient = DefaultHTTPClient()
    self.assetRetriever = AssetRetriever(httpClient: httpClient)
    self.publicationOpener = PublicationOpener(
      parser: DefaultPublicationParser(
        httpClient: httpClient,
        assetRetriever: assetRetriever,
        pdfFactory: DefaultPDFDocumentFactory()
      ),
      contentProtections: [contentProtection]
    )
  }

  /// Get PDF file name from the manifest file.
  private func getPdfHref(completion: @escaping (_ pdfHref: String?, _ error: NSError?) -> ()) {
    let manifestPath = "manifest.json"
    guard let fileUrl = FileURL(url: self.pdfUrl) else {
      completion(nil, nil)
      return 
    }

    Task {
      switch await assetRetriever.retrieve(url: fileUrl) {
      case .success(let asset):
        let result = await publicationOpener.open(asset: asset, allowUserInteraction: false, sender: nil)

        switch result {
        case .success(let publication):
          do {
            guard let resource = publication.getResource(at: manifestPath) else {
              completion(nil,nil)
              return
            }

            switch await resource.readAsJSONObject() {
            case .success(let jsonObject):
              let jsonData = try JSONSerialization.data(withJSONObject: jsonObject)
              let pdfManifest = try JSONDecoder().decode(PDFManifest.self, from: jsonData)
              completion(pdfManifest.readingOrder.first?.href, nil)
            case .failure(let error):
              throw error
            }
          } catch {
            TPPErrorLogger.logError(error, summary: "Error reading PDF path")
            let nsError = NSError(domain: "Palace.LCPPDFs", code: 0, userInfo: [
              NSLocalizedDescriptionKey: error.localizedDescription,
              "Error": error
            ])
            completion(nil, nsError)
          }

        case .failure(let error):
          TPPErrorLogger.logError(error, summary: "Failed to open LCP PDF")
          completion(nil, NSError(domain: error.localizedDescription, code: -1))
        }

      case .failure(let error):
        TPPErrorLogger.logError(error, summary: "Failed to retrieve LCP PDF asset")
        completion(nil, NSError(domain: error.localizedDescription, code: -1))
      }
    }
  }

  /// Decrypting data takes time;
  /// PDF data provider reads data in consequent blocks for several bytes to ~16kb,
  /// caching decrypted data between reads improves reading speed a lot
  private var dataCache: Data?
  private var dataCacheSize = 1024 * 1024
  private var dataCachePage: Int?

  /// Update cached data
  /// - Parameters:
  ///   - encryptedData: Encrypted data
  ///   - page: offset in `dataCacheSize` pages of data to cache
  private func updateCache(data encryptedData: Data, page: Int) {
    let start = page * dataCacheSize
    let end = min(encryptedData.count, start + dataCacheSize)
    dataCache = decryptRawData(data: encryptedData, start: start, end: end)
    if dataCache == nil {
      dataCachePage = nil
    } else {
      dataCachePage = page
    }
  }

  /// Simple cache read function
  /// - Parameters:
  ///   - start: Start position of the block to read
  ///   - end: End position of the block to read
  /// - Returns: Decrypted data from `dataCache`; nil of `start` or `end` miss the cache.
  private func readCached(start: Int, end: Int) -> Data? {
    guard let data = dataCache else {
      return nil
    }
    let cacheStart = start % dataCacheSize
    let cacheEnd = end % dataCacheSize
    return data[cacheStart..<cacheEnd]
  }

  /// Decrypt data
  /// - Parameters:
  ///   - encryptedData: Encrypted data
  ///   - start: Start position of the block to decrypt
  ///   - end: End position of the block to decrypt
  /// - Returns: Decrypted data
  ///
  /// This funciton tries to read decrypted data for cache, then from encrypted data
  @objc func decryptData(data encryptedData: Data, start: Int, end: Int) -> Data? {
    let startPage = start / dataCacheSize
    let endPage = end / dataCacheSize
    var data: Data?
    if startPage == endPage {
      if startPage != dataCachePage {
        updateCache(data: encryptedData, page: startPage)
      }
      data = readCached(start: start, end: end)
    }
    return data ?? decryptRawData(data: encryptedData, start: start, end: end)
  }

  /// Decrypt data
  /// - Parameters:
  ///   - encryptedData: Encrypted data
  ///   - start: Start position of the block to decrypt
  ///   - end: End position of the block to decrypt
  /// - Returns: Decrypted data
  ///
  /// This function reads and decrypts raw encrypted data without caching.
  private func decryptRawData(data encryptedData: Data, start: Int, end: Int) -> Data? {
    autoreleasepool {
      let aesBlockSize = 4096 // should be a multiple of 16; smaller and larger block sizes slow reading down
      let paddingSize = 16    // AES padding size; lcpService cuts it off
      let paddingData = Data(Array<UInt8>(repeating: 0, count: paddingSize))
      let blockStart = (start / aesBlockSize) * aesBlockSize  // align to aesBlockSize
      let blockEnd = (end / aesBlockSize + ( end % aesBlockSize == 0 ? 0 : 1 )) * aesBlockSize
      let range = blockStart..<min(blockEnd, encryptedData.count)
      let encryptedBlock = encryptedData.subdata(in: range) + paddingData // lcpService.decrypt cuts off padding
      let decryptedBlock = self.lcpService.decrypt(data: encryptedBlock)
      let resultStart = start - blockStart  // cut off aligned block of data to start ...
      let resultEnd = end - blockStart      // ...and end positions
      let resultRange = resultStart..<resultEnd
      return decryptedBlock?.subdata(in: resultRange)
    }
  }

  /// Returns URL in temporary directory for the file
  /// - Parameter url: Arcive URL
  /// - Returns: URL in temporary directory for extracted PDF file
  @objc static func temporaryUrlForPDF(url: URL) -> URL {
    let filename = "\(url.lastPathComponent).pdf"
    return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
  }

  /// Extract PDF from `.zip` archive
  /// - Parameters:
  ///   - url: Source `.zip` archive with PDF file
  ///   - completion: `URL` of the unarchived file, `Error` in case of an error
  @objc func extract(url: URL, completion: @escaping (_ resultUrl: URL?, _ error: Error?) -> Void) {
    let resultUrl = LCPPDFs.temporaryUrlForPDF(url: url)
    getPdfHref { pdfHref, error in
      if FileManager.default.fileExists(atPath: resultUrl.path) {
        completion(resultUrl, nil)
        return
      }
      guard let pdfHref = pdfHref else {
        completion(nil, nil)
        return
      }
      guard let archive = Archive(url: url, accessMode: .read) else {
        completion(nil, nil)
        return
      }
      guard let pdfEntry = archive[pdfHref] else {
        completion(nil, nil)
        return
      }
      do {
        _ = try archive.extract(pdfEntry, to: resultUrl)
        completion(resultUrl, nil)
      } catch {
        completion(nil, error)
      }
    }
  }

  /// Delete temporary unarchived file content, if it exists
  /// - Parameter url: PDF archive URL
  @objc static func deletePdfContent(url: URL) throws {
    let contentUrl = temporaryUrlForPDF(url: url)
    if FileManager.default.fileExists(atPath: contentUrl.path) {
      try FileManager.default.removeItem(at: contentUrl)
    }
  }
}

private extension Publication {
  func getResource(at path: String) -> Resource? {
    if let link = findLink(at: path) {
      return get(link)
    }

    let leadingSlashPath = "/" + path
    if let link = findLink(at: leadingSlashPath) {
      return get(link)
    }

    return FailureResource(error: .access(.fileSystem(.fileNotFound(nil))))
  }

  private func findLink(at path: String) -> ReadiumShared.Link? {
    if let link = readingOrder.first(where: { $0.href == path }) {
      return link
    }

    if let link = resources.first(where: { $0.href == path }) {
      return link
    }

    return nil
  }
}

#endif
