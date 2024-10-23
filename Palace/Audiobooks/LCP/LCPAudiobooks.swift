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

          // Convert the Data to a JSON object
          do {
            if let jsonObject = try JSONSerialization.jsonObject(with: jsonData, options: []) as? NSDictionary {
              completion(jsonObject, nil) // Success, pass the JSON dictionary to the completion
            } else {
              TPPErrorLogger.logError(nil, summary: "Failed to convert manifest data to JSON object.", metadata: [self.audiobookUrlKey: self.audiobookUrl])
              completion(nil, nil) // Error converting the manifest data to a JSON object
            }
          } catch {
            TPPErrorLogger.logError(error, summary: "Error parsing JSON manifest.", metadata: [self.audiobookUrlKey: self.audiobookUrl])
            completion(nil, LCPAudiobooks.nsError(for: error)) // Pass the error through
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

/// DRM Decryptor for LCP audiobooks
extension LCPAudiobooks: DRMDecryptor {
  
  /// Decrypt protected file
  /// - Parameters:
  ///   - url: encrypted file URL.
  ///   - resultUrl: URL to save decrypted file at.
  ///   - completion: decryptor callback with optional `Error`.
  func decrypt(url: URL, to resultUrl: URL, completion: @escaping (Error?) -> Void) {
    Task {
      switch await assetRetriever.retrieve(url: audiobookUrl) {
      case .success(let asset):
        let result = await publicationOpener.open(asset: asset, allowUserInteraction: false, sender: nil)

        switch result {
        case .success(let publication):
          do {
            guard let resource = publication.getResource(at: url.path) else {
              completion(nil)
              return
            }

            let data = try await resource.read().get()
            try data.write(to: resultUrl)
            completion(nil)
          } catch {
            completion(error)
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
    let resource = get(Link(href: "/" + path))
    guard type(of: resource) != FailureResource.self else {
      return get(Link(href:path))
    }

    return resource
  }
}
#endif
