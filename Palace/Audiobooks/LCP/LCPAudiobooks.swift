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

/// LCP Audiobooks helper class
@objc class LCPAudiobooks: NSObject {
  
  private let audiobookUrlKey = "audiobookUrl"
  private let audioFileHrefKey = "audioFileHref"
  private let destinationFileUrlKey = "destinationFileUrl"
  private static let expectedAcquisitionType = "application/vnd.readium.lcp.license.v1.0+json"
  
  private let audiobookUrl: AbsoluteURL
  private let lcpService = LCPLibraryService()
  private let assetRetriever: AssetRetriever
  private let publicationOpener: PublicationOpener

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

    self.assetRetriever = AssetRetriever(httpClient: DefaultHTTPClient())

    guard let contentProtection = lcpService.contentProtection else {
      TPPErrorLogger.logError(nil, summary: "Uninitialized contentProtection in LCPAudiobooks")
      return nil
    }

    let parser = DefaultPublicationParser(
      httpClient: DefaultHTTPClient(),
      assetRetriever: assetRetriever,
      pdfFactory: DefaultPDFDocumentFactory()
    )

    self.publicationOpener = PublicationOpener(
      parser: parser,
      contentProtections: [contentProtection]
    )
  }

  /// Content dictionary for `AudiobookFactory`
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
}

///// DRM Decryptor for LCP audiobooks
extension LCPAudiobooks: DRMDecryptor {

  /// Get streamable resource URL for AVPlayer (for true streaming without local files)
  /// - Parameters:
  ///   - trackPath: internal track path from manifest (e.g., "track1.mp3")
  ///   - completion: callback with streamable URL or error
  @objc func getStreamableURL(for trackPath: String, completion: @escaping (URL?, Error?) -> Void) {
    Task {
      let result = await self.assetRetriever.retrieve(url: audiobookUrl)
      switch result {
      case .success(let asset):
        let publicationResult = await publicationOpener.open(asset: asset, allowUserInteraction: false, sender: nil)
        switch publicationResult {
        case .success(let publication):
          if let resource = publication.getResource(at: trackPath) {
            // For LCP streaming, we need to create a custom URL that can be handled by Readium
            // This would ideally be a streamable URL that AVPlayer can use
            // For now, let's construct the HTTP URL manually based on the publication URL
            if let httpUrl = constructStreamingURL(for: trackPath) {
              completion(httpUrl, nil)
            } else {
              completion(nil, NSError(domain: "LCPStreaming", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to construct streaming URL"]))
            }
          } else {
            completion(nil, NSError(domain: "AudiobookResourceError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Resource not found"]))
          }
        case .failure(let error):
          completion(nil, error)
        }
      case .failure(let error):
        completion(nil, error)
      }
    }
  }
  
  /// Construct HTTP streaming URL for a track path
  private func constructStreamingURL(for trackPath: String) -> URL? {
    // The audiobookUrl should be the HTTP publication URL when streaming
    guard let httpUrl = audiobookUrl as? HTTPURL else {
      return nil
    }
    
    // Construct the full HTTP URL for the track
    let baseUrl = httpUrl.url
    return URL(string: trackPath, relativeTo: baseUrl)
  }

  /// Decrypt protected file
  /// - Parameters:
  ///   - url: encrypted file URL.
  ///   - resultUrl: URL to save decrypted file at.
  ///   - completion: decryptor callback with optional `Error`.
  func decrypt(url: URL, to resultUrl: URL, completion: @escaping (Error?) -> Void) {
    Task {
      let result = await self.assetRetriever.retrieve(url: audiobookUrl)
      switch result {
      case .success(let asset):
        let publicationResult = await publicationOpener.open(asset: asset, allowUserInteraction: false, sender: nil)
        switch publicationResult {
        case .success(let publication):
          if let resource = publication.getResource(at: url.path) {
            do {
              let data = try await resource.read().get()
              try data.write(to: resultUrl, options: .atomic)
              completion(nil)
            } catch {
              completion(error)
            }
          } else {
            completion(NSError(domain: "AudiobookResourceError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Resource not found"]))
          }
        case .failure(let error):
          completion(error)
        }
      case .failure(let error):
        completion(error)
      }
    }
  }
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
#endif
