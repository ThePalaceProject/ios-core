//
//  LCPPDFs.swift
//  Palace
//
//  Created by Maurice Carrier on 3/22/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

#if LCP

import Foundation
import R2Shared
import R2Streamer
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
    guard let defualtAcquisition = book.defaultAcquisition() else { return false }
    return book.defaultBookContentType() == .PDF && defualtAcquisition.type == expectedAcquisitionType
  }
  
  private let pdfUrl: URL
  private var lcpService = LCPLibraryService()
  private let streamer: Streamer
  
  
  @objc init?(url: URL) {
    guard let contentProtection = lcpService.contentProtection else {
      TPPErrorLogger.logError(nil, summary: "Uninitialized contentProtection in LCPPDFs")
      return nil
    }
    self.pdfUrl = url
    self.streamer = Streamer(contentProtections: [contentProtection])
  }
  
  /// Content dictionary for `AudiobookFactory`
  private func getPdfHref(completion: @escaping (_ pdfHref: String?, _ error: NSError?) -> ()) {
    let manifestPath = "manifest.json"
    let asset = FileAsset(url: self.pdfUrl)
    streamer.open(asset: asset, allowUserInteraction: false) { result in
      do {
        let publication = try result.get()
        let resource = publication.getResource(at: manifestPath)
        let manifestData = try resource.read().get()
        let pdfManifest = try JSONDecoder().decode(PDFManifest.self, from: manifestData)
        resource.close()
        completion(pdfManifest.readingOrder.first?.href, nil)
      } catch {
        
//        TPPErrorLogger.logError(error, summary: "Error reading LCP \(manifestPath) file", metadata: [self.audiobookUrlKey: self.pdfUrl])
//        completion(nil, LCPAudiobooks.nsError(for: error))
        completion(nil, nil)
      }
    }
  }

  private var dataCache: Data?
  private var dataCacheSize = 1024 * 1024
  private var dataCachePage: Int?
  
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
  
  private func readCached(start: Int, end: Int) -> Data? {
    guard let data = dataCache else {
      return nil
    }
    let cacheStart = start % dataCacheSize
    let cacheEnd = end % dataCacheSize
    return data[cacheStart..<cacheEnd]
  }

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

  private func decryptRawData(data encryptedData: Data, start: Int, end: Int) -> Data? {
    autoreleasepool {
      let aesBlockSize = 4096 // should be a multiple of 16; smaller and larger blocks slow reading down
      let paddingSize = 16
      let paddingData = Data(Array<UInt8>(repeating: 0, count: paddingSize))
      let blockStart = (start / aesBlockSize) * aesBlockSize
      let blockEnd = (end / aesBlockSize + ( end % aesBlockSize == 0 ? 0 : 1 )) * aesBlockSize
      let range = blockStart..<min(blockEnd, encryptedData.count)
      let encryptedBlock = encryptedData.subdata(in: range) + paddingData // lcpService.decrypt cuts off padding
      let decryptedBlock = self.lcpService.decrypt(data: encryptedBlock)
      let resultStart = start - blockStart
      let resultEnd = end - blockStart
      let resultRange = resultStart..<resultEnd
      return decryptedBlock?.subdata(in: resultRange)
    }
  }

  @objc func extract(url: URL, completion: @escaping (_ resultUrl: URL?, _ error: Error?) -> Void) {
    let resultUrl = FileManager.default.temporaryDirectory.appendingUniquePathComponent("\(UUID().uuidString).pdf")
    getPdfHref { pdfHref, error in
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
}

private extension Publication {
  // R2 has changed its expectation about the leading slash;
  // here we verify both cases.
  func getResource(at path: String) -> Resource {
    let resource = get("/" + path)
    guard type(of: resource) != FailureResource.self else {
      return get(path)
    }
    return resource
  }
}

#endif

