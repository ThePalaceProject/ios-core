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
  
  private var cachedPublication: Publication?
  private let publicationCacheLock = NSLock()
  private var currentPrefetchTask: Task<Void, Never>?

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
    // Cancel any prior prefetch task to avoid duplicate work
    publicationCacheLock.lock()
    currentPrefetchTask?.cancel()
    publicationCacheLock.unlock()

    let task = Task { [weak self] in
      guard let self else { return }
      if Task.isCancelled { return }

      switch await assetRetriever.retrieve(url: audiobookUrl) {
      case .success(let asset):
        if Task.isCancelled { return }
        let result = await publicationOpener.open(asset: asset, allowUserInteraction: false, sender: nil)

        switch result {
        case .success(let publication):
          if Task.isCancelled { return }
          publicationCacheLock.lock()
          cachedPublication = publication
          publicationCacheLock.unlock()
          
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

      self.publicationCacheLock.lock()
      if self.currentPrefetchTask?.isCancelled == true { self.currentPrefetchTask = nil }
      self.publicationCacheLock.unlock()
    }

    publicationCacheLock.lock()
    currentPrefetchTask = task
    publicationCacheLock.unlock()
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

extension LCPAudiobooks: LCPStreamingProvider {
  
  public func getPublication() -> Publication? {
    publicationCacheLock.lock()
    defer { publicationCacheLock.unlock() }
    return cachedPublication
  }
  
  public func supportsStreaming() -> Bool {
    return true
  }
  
  public func setupStreamingFor(_ player: Any) -> Bool {
    guard let streamingPlayer = player as? StreamingCapablePlayer else {
      ATLog(.error, "🎵 [LCPAudiobooks] Player does not support streaming")
      return false
    }
    
    publicationCacheLock.lock()
    let hasPublication = cachedPublication != nil
    publicationCacheLock.unlock()
    
    if !hasPublication {
      let semaphore = DispatchSemaphore(value: 0)
      var loadSuccess = false
      
      loadContentDictionary { json, error in
        loadSuccess = (json != nil && error == nil)
        semaphore.signal()
      }
      
      semaphore.wait()
      
      if !loadSuccess {
        return false
      }
    }
    
    streamingPlayer.setStreamingProvider(self)
    return true
  }
}

// MARK: - Cached manifest access
extension LCPAudiobooks {
  /// Returns the cached content dictionary if the publication has already been opened.
  /// This avoids re-opening the asset and enables immediate UI presentation.
  public func cachedContentDictionary() -> NSDictionary? {
    publicationCacheLock.lock()
    let publication = cachedPublication
    publicationCacheLock.unlock()

    guard let publication, let jsonManifestString = publication.jsonManifest,
          let jsonData = jsonManifestString.data(using: .utf8) else {
      return nil
    }

    if let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? NSDictionary {
      return jsonObject
    }
    return nil
  }

  /// Start a cancellable background prefetch of the publication/manifest
  public func startPrefetch() {
    // Kick off a background load; completion is ignored
    self.contentDictionary { _, _ in }
  }

  /// Cancel any in-flight prefetch task
  public func cancelPrefetch() {
    publicationCacheLock.lock()
    currentPrefetchTask?.cancel()
    currentPrefetchTask = nil
    publicationCacheLock.unlock()
  }
}

extension LCPAudiobooks: DRMDecryptor {

  /// Get streamable resource URL for AVPlayer (for true streaming without local files)
  /// - Parameters:
  ///   - trackPath: internal track path from manifest (e.g., "track1.mp3")
  ///   - completion: callback with streamable URL or error
  @objc func getStreamableURL(for trackPath: String, completion: @escaping (URL?, Error?) -> Void) {
    // Use fast URL construction first (avoids expensive license processing)
    if let streamingUrl = constructStreamingURL(for: trackPath) {
      completion(streamingUrl, nil)
      return
    }
    
    Task {
      let publication = await getCachedPublication()
      
      switch publication {
      case .success(let pub):
        if let resource = pub.getResource(at: trackPath) {
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
    }
  }
  
  func getPublication(completion: @escaping (Publication?, Error?) -> Void) {
    Task {
      let result = await getCachedPublication()
      switch result {
      case .success(let publication):
        completion(publication, nil)
      case .failure(let error):
        completion(nil, error)
      }
    }
  }
  
  /// Get cached publication or load it if not cached
  private func getCachedPublication() async -> Result<Publication, Error> {
    publicationCacheLock.lock()
    defer { publicationCacheLock.unlock() }
    
    if let cached = cachedPublication {
      return .success(cached)
    }
    
    let result = await self.assetRetriever.retrieve(url: audiobookUrl)
    switch result {
    case .success(let asset):
      let publicationResult = await publicationOpener.open(asset: asset, allowUserInteraction: false, sender: nil)
      switch publicationResult {
      case .success(let publication):
        cachedPublication = publication
        return .success(publication)
      case .failure(let error):
        return .failure(error)
      }
    case .failure(let error):
      return .failure(error)
    }
  }
  
  private func constructStreamingURL(for trackPath: String) -> URL? {
    if let httpUrl = audiobookUrl as? HTTPURL {
      return URL(string: trackPath, relativeTo: httpUrl.url)
    }

    guard let fileUrl = audiobookUrl as? FileURL else {
      return nil
    }

    var licenseURL = fileUrl.url
    if licenseURL.pathExtension.lowercased() != "lcpl" {
      let sibling = licenseURL.deletingPathExtension().appendingPathExtension("lcpl")
      if FileManager.default.fileExists(atPath: sibling.path) {
        licenseURL = sibling
      } else {
        let dir = licenseURL.deletingLastPathComponent()
        if let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
           let found = contents.first(where: { $0.pathExtension.lowercased() == "lcpl" }) {
          licenseURL = found
        } else {
          TPPErrorLogger.logError(nil, summary: "LCP streaming: license file not found near content", metadata: [
            "contentURL": licenseURL.absoluteString
          ])
          return nil
        }
      }
    }

    do {
      let licenseData = try Data(contentsOf: licenseURL)
      guard let licenseJson = try JSONSerialization.jsonObject(with: licenseData) as? [String: Any] else {
        TPPErrorLogger.logError(nil, summary: "LCP streaming: license is not valid JSON", metadata: [
          "licenseURL": licenseURL.absoluteString
        ])
        return nil
      }

      if let links = licenseJson["links"] as? [[String: Any]] {

        for link in links {
          if let rel = link["rel"] as? String,
             rel == "publication",
             let href = link["href"] as? String,
             let publicationUrl = URL(string: href) {
            return URL(string: trackPath, relativeTo: publicationUrl)
          }
        }
      }

      TPPErrorLogger.logError(nil, summary: "LCP streaming: publication link not found in license", metadata: [
        "licenseURL": licenseURL.absoluteString
      ])
    } catch {
      TPPErrorLogger.logError(error, summary: "Failed to read/parse license file for streaming URL construction", metadata: [
        "licenseURL": licenseURL.absoluteString
      ])
    }

    return nil
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
    let resource = get(Link(href: path))
    guard type(of: resource) != FailureResource.self else {
      return get(Link(href: "/" + path))
    }

    return resource
  }
}
#endif
