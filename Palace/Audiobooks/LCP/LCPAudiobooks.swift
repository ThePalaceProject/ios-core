//
//  LCPAudiobooks.swift
//  The Palace Project
//
//  Created by Vladimir Fedorov on 16.11.2020.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

#if LCP

import Foundation
import R2Shared
import R2Streamer
import ReadiumLCP
import PalaceAudiobookToolkit

/// LCP Audiobooks helper class
@objc class LCPAudiobooks: NSObject {
  
  private let audiobookUrlKey = "audiobookUrl"
  private let audioFileHrefKey = "audioFileHref"
  private let destinationFileUrlKey = "destinationFileUrl"
  private static let expectedAcquisitionType = "application/vnd.readium.lcp.license.v1.0+json"
  
  private let audiobookUrl: URL
  private let lcpService = LCPLibraryService()
  private let streamer: Streamer
  
  /// Initialize for an LCP audiobook
  /// - Parameter audiobookUrl: must be a file with `.lcpa` extension
  @objc init?(for audiobookUrl: URL) {
    // Check contentProtection is in place
    guard let contentProtection = lcpService.contentProtection else {
      TPPErrorLogger.logError(nil, summary: "Uninitialized contentProtection in LCPAudiobooks")
      return nil
    }
    self.audiobookUrl = audiobookUrl
    self.streamer = Streamer(contentProtections: [contentProtection])
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
    let manifestPath = "manifest.json"
    let asset = FileAsset(url: self.audiobookUrl)
    streamer.open(asset: asset, allowUserInteraction: false) { result in
      switch result {
      case .success(let publication):
        do {
          let resource = publication.getResource(at: manifestPath)
          let json = try resource.readAsJSON().get()
          completion(json as NSDictionary, nil)
        } catch {
          TPPErrorLogger.logError(error, summary: "Error reading LCP \(manifestPath) file", metadata: [self.audiobookUrlKey: self.audiobookUrl])
          completion(nil, LCPAudiobooks.nsError(for: error))
        }
      case .failure(let error):
        TPPErrorLogger.logError(error, summary: "Failed to open LCP audiobook", metadata: [self.audiobookUrlKey: self.audiobookUrl])
        completion(nil, LCPAudiobooks.nsError(for: error))
      case .cancelled:
        completion(nil, nil)

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
    let description = (error as? LCPError)?.errorDescription ?? error.localizedDescription
    return NSError(domain: "SimplyE.LCPAudiobooks", code: 0, userInfo: [
      NSLocalizedDescriptionKey: description,
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
    DispatchQueue.global(qos: .userInitiated).async {
      self.decryptFile(at: url, to: resultUrl, completion: completion)
    }
  }
  
  private func decryptFile(at url: URL, to resultUrl: URL, completion: @escaping (Error?) -> Void) {
    let asset = FileAsset(url: self.audiobookUrl)
    streamer.open(asset: asset, allowUserInteraction: false) { result in
      switch result {
      case .success(let publication):
        do {
          let resource = publication.getResource(at: url.path)
          let data = try resource.read().get()
          try data.write(to: resultUrl)
          completion(nil)
        } catch {
          TPPErrorLogger.logError(error, summary: "Error decrypting LCP audio file", metadata: [
            self.audiobookUrlKey: self.audiobookUrl,
            self.audioFileHrefKey: url,
            self.destinationFileUrlKey: resultUrl
          ])
          completion(error)
        }
      case .failure(let error):
        TPPErrorLogger.logError(error, summary: "Failed to decrypt LCP audiobook", metadata: [self.audiobookUrlKey: self.audiobookUrl])
        completion(error)
      case .cancelled:
        completion(nil)
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
