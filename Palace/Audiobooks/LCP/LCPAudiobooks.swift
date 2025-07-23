//
//  LCPAudiobooks.swift
//  The Palace Project
//
//  Created by Vladimir Fedorov on 16.11.2020.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

#if LCP

import Foundation
import ReadiumShared
import ReadiumStreamer
import ReadiumLCP
import PalaceAudiobookToolkit

@objc class LCPAudiobooks: NSObject {
  
  private let audiobookUrlKey = "audiobookUrl"
  private let audioFileHrefKey = "audioFileHref"
  private let destinationFileUrlKey = "destinationFileUrl"
  private static let expectedAcquisitionType = "application/vnd.readium.lcp.license.v1.0+json"
  
  private let audiobookUrl: AbsoluteURL
  private let lcpService = LCPLibraryService()
  private let assetRetriever: AssetRetriever
  private let httpRangeRetriever: HTTPRangeRetriever
  private let publicationOpener: PublicationOpener
  
  private var _publication: Publication?
  private let publicationLock = NSLock()

  /// Initialize for an LCP audiobook
  /// - Parameter audiobookUrl: must be a file with `.lcpa` extension
  @objc init?(for audiobookUrl: URL) {

    if let fileUrl = FileURL(url: audiobookUrl) {
      self.audiobookUrl = fileUrl
    } else if let httpUrl = HTTPURL(url: audiobookUrl) {
      self.audiobookUrl = httpUrl
    } else {
      return nil
    }

    let httpClient = DefaultHTTPClient()
    self.assetRetriever = AssetRetriever(httpClient: httpClient)
    self.httpRangeRetriever = HTTPRangeRetriever(httpClient: httpClient)

    guard let contentProtection = lcpService.contentProtection else {
      TPPErrorLogger.logError(nil, summary: "Uninitialized contentProtection in LCPAudiobooks")
      return nil
    }

    let parser = DefaultPublicationParser(
      httpClient: httpClient,
      assetRetriever: assetRetriever,
      pdfFactory: DefaultPDFDocumentFactory()
    )

    self.publicationOpener = PublicationOpener(
      parser: parser,
      contentProtections: [contentProtection]
    )
  }

  @objc func contentDictionary(completion: @escaping (_ json: NSDictionary?, _ error: NSError?) -> ()) {
    DispatchQueue.global(qos: .userInitiated).async {
      self.loadContentDictionary { json, error in
        DispatchQueue.main.async {
          completion(json, error)
        }
      }
    }
  }
  
  private func loadContentDictionary(completion: @escaping (_ json: NSDictionary?, _ error: NSError?) -> ()) {
    Task {
      switch await assetRetriever.retrieve(url: audiobookUrl) {
      case .success(let asset):
        let result = await publicationOpener.open(asset: asset, allowUserInteraction: false, sender: nil)

        switch result {
        case .success(let publication):
          publicationLock.lock()
          _publication = publication
          publicationLock.unlock()
          
          guard let jsonManifestString = publication.jsonManifest else {
            TPPErrorLogger.logError(nil, summary: "No resource found for audiobook.", metadata: [self.audiobookUrlKey: self.audiobookUrl])
            completion(nil, nil)
            return 
          }

          guard let jsonData = jsonManifestString.data(using: .utf8) else {
            TPPErrorLogger.logError(nil, summary: "Failed to convert manifest string to data.", metadata: [self.audiobookUrlKey: self.audiobookUrl])
            completion(nil, nil)
            return
          }

          do {
            if let jsonObject = try JSONSerialization.jsonObject(with: jsonData, options: []) as? NSDictionary {
              completion(jsonObject, nil)
            } else {
              TPPErrorLogger.logError(nil, summary: "Failed to convert manifest data to JSON object.", metadata: [self.audiobookUrlKey: self.audiobookUrl])
              completion(nil, nil)
            }
          } catch {
            TPPErrorLogger.logError(error, summary: "Error parsing JSON manifest.", metadata: [self.audiobookUrlKey: self.audiobookUrl])
            completion(nil, LCPAudiobooks.nsError(for: error))
          }
        case .failure(let error):
          TPPErrorLogger.logError(error, summary: "Failed to open LCP audiobook", metadata: [self.audiobookUrlKey: self.audiobookUrl])
          completion(nil, LCPAudiobooks.nsError(for: error))
        }

      case .failure(let error):
        TPPErrorLogger.logError(error, summary: "Failed to retrieve audiobook asset", metadata: [self.audiobookUrlKey: self.audiobookUrl])
        completion(nil, LCPAudiobooks.nsError(for: error))
      }
    }
  }

  /// Check if the book is LCP audiobook
  /// - Parameter book: audiobook
  /// - Returns: `true` if the book is an LCP DRM protected audiobook, `false` otherwise
  @objc static func canOpenBook(_ book: TPPBook) -> Bool {
    guard let defaultAcquisition = book.defaultAcquisition else { return false }
    return book.defaultBookContentType == .audiobook && defaultAcquisition.type == expectedAcquisitionType
  }
  
  /// Creates an NSError for Objective-C code
  /// - Parameter error: Error object
  /// - Returns: NSError object
  private static func nsError(for error: Error) -> NSError {
    return NSError(domain: "SimplyE.LCPAudiobooks", code: 0, userInfo: [
      NSLocalizedDescriptionKey: error.localizedDescription,
      "Error": error
    ])
  }
  
  // MARK: - Streaming Support
  
  /// Get the LCP publication for streaming use
  /// - Returns: The opened Publication object, or nil if not available
  func getPublication() -> Publication? {
    publicationLock.lock()
    defer { publicationLock.unlock() }
    return _publication
  }
  
  /// Get the HTTP range retriever for streaming operations
  /// - Returns: The HTTPRangeRetriever instance
  func getHTTPRangeRetriever() -> HTTPRangeRetriever {
    return httpRangeRetriever
  }
}

///// DRM Decryptor for LCP audiobooks
extension LCPAudiobooks: DRMDecryptor {

  /// Decrypt protected file
  /// - Parameters:
  ///   - url: encrypted file URL.
  ///   - resultUrl: URL to save decrypted file at.
  ///   - completion: decryptor callback with optional `Error`.
  func decrypt(url: URL, to resultUrl: URL, completion: @escaping (Error?) -> Void) {
      decryptForStreaming(url: url, to: resultUrl, completion: completion)
  }
  
  private func decryptForStreaming(url: URL, to resultUrl: URL, completion: @escaping (Error?) -> Void) {
    TPPErrorLogger.logError(nil, summary: "Full-file decryption called in streaming mode - this should not happen", metadata: [
      "url": url.absoluteString,
      "resultUrl": resultUrl.absoluteString
    ])
    
    completion(NSError(domain: "LCPStreamingError", code: -1, userInfo: [
      NSLocalizedDescriptionKey: "Full-file decryption not supported in streaming mode"
    ]))
  }
}

// MARK: - LCP Range Decryption Support

extension LCPAudiobooks: LCPStreamingDecryptor {
  
  /// Decrypt a specific byte range of LCP-protected content
  /// - Parameters:
  ///   - url: The URL of the resource within the LCP container
  ///   - range: The byte range to decrypt
  ///   - completion: Completion handler with decrypted data or error
  func decryptRange(url: URL, range: Range<Int>, completion: @escaping (Result<Data, Error>) -> Void) {
    Task {
      do {
        guard let publication = getPublication() else {
          throw NSError(domain: "LCPStreamingError", code: -3, userInfo: [
            NSLocalizedDescriptionKey: "No publication available for range decryption"
          ])
        }
        
        guard let resource = publication.getResource(at: url.path) else {
          throw NSError(domain: "LCPStreamingError", code: -4, userInfo: [
            NSLocalizedDescriptionKey: "Resource not found: \(url.path)"
          ])
        }
        
        let uint64Range = UInt64(range.lowerBound)..<UInt64(range.upperBound)
        let decryptedData = await resource.read(range: uint64Range)
        
        completion(decryptedData.eraseToAnyError())
        
      } catch {
        completion(.failure(error))
      }
    }
  }
}

// MARK: - LCPStreamingDecryptor Protocol

/// Protocol for range-based LCP decryption during streaming
 protocol LCPStreamingDecryptor {
  /// Decrypt a specific byte range of LCP-protected content
  /// - Parameters:
  ///   - url: The URL of the resource within the LCP container
  ///   - range: The byte range to decrypt
  ///   - completion: Completion handler with decrypted data or error
  func decryptRange(url: URL, range: Range<Int>, completion: @escaping (Result<Data, Error>) -> Void)
}

private extension Publication {
  func getResource(at path: String) -> Resource? {
    // Directly pass the path without prepending "/"
    let resource = get(Link(href: path))
    guard type(of: resource) != FailureResource.self else {
      // Attempt again with prepending "/"
      return get(Link(href: "/" + path))
    }

    return resource
  }
}

extension LCPAudiobooks: LCPStreamingProvider {}
#endif
