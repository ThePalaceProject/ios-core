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
  private let licenseUrl: URL?
  private let lcpLibraryService = LCPLibraryService()
  private let assetRetriever: AssetRetriever
  private let publicationOpener: PublicationOpener
  private let httpClient: DefaultHTTPClient
  
  private var cachedPublication: Publication?
  private let publicationCacheLock = NSLock()
  private var currentPrefetchTask: Task<Void, Never>?
  private var containerURL: URL?

  /// Initialize for an LCP audiobook
  /// - Parameter audiobookUrl: can be a local `.lcpa` package URL OR an `.lcpl` license URL for streaming
  /// - Parameter licenseUrl: optional license URL for streaming authentication (deprecated, use audiobookUrl)
  @objc init?(for audiobookUrl: URL, licenseUrl: URL? = nil) {

    if let fileUrl = FileURL(url: audiobookUrl) {
      self.audiobookUrl = fileUrl
    } else if let httpUrl = HTTPURL(url: audiobookUrl) {
      self.audiobookUrl = httpUrl
    } else {
      return nil
    }

    self.licenseUrl = licenseUrl ?? (audiobookUrl.pathExtension.lowercased() == "lcpl" ? audiobookUrl : nil)

    let httpClient = DefaultHTTPClient()
    self.httpClient = httpClient
    self.assetRetriever = AssetRetriever(httpClient: httpClient)

    guard let contentProtection = lcpService.contentProtection else {
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
    publicationCacheLock.lock()
    currentPrefetchTask?.cancel()
    publicationCacheLock.unlock()

    let task = Task { [weak self] in
      guard let self else { return }
      if Task.isCancelled { return }

      var urlToOpen: AbsoluteURL = audiobookUrl
      if let licenseUrl {
        if let fileUrl = FileURL(url: licenseUrl) {
          urlToOpen = fileUrl
        } else if let httpUrl = HTTPURL(url: licenseUrl) {
          urlToOpen = httpUrl
        } else {
          completion(nil, NSError(domain: "LCPAudiobooks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid license URL"]))
          return
        }
      }
      
      let result = await assetRetriever.retrieve(url: urlToOpen)
      
      switch result {
      case .success(let asset):
        if Task.isCancelled { return }
        
        let hostVC = TPPRootTabBarController.shared()
        
        var credentials: String? = nil
        if let licenseUrl = licenseUrl, licenseUrl.isFileURL {
          credentials = try? String(contentsOf: licenseUrl)
        }
        
        let result = await publicationOpener.open(asset: asset, allowUserInteraction: true, credentials: credentials, sender: hostVC)

        switch result {
        case .success(let publication):
          
          if Task.isCancelled { return }
          publicationCacheLock.lock()
          cachedPublication = publication
          publicationCacheLock.unlock()
          
          if let jsonManifestString = publication.jsonManifest, let jsonData = jsonManifestString.data(using: .utf8),
             let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? NSDictionary {
            completion(jsonObject, nil)
          } else {
            let links = publication.readingOrder.map { link in
              let hrefString = String(describing: link.href)
              let typeString = link.mediaType.map { String(describing: $0) } ?? "audio/mpeg"
              return [
                "href": hrefString,
                "type": typeString
              ]
            }
            let minimal: [String: Any] = [
              "metadata": [
                "identifier": UUID().uuidString,
                "title": String(describing: publication.metadata.title)
              ],
              "readingOrder": links
            ]
            completion(minimal as NSDictionary, nil)
          }
        case .failure(let error):
          completion(nil, LCPAudiobooks.nsError(for: error))
        }

      case .failure(let error):
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
    return NSError(domain: "Palace.LCPAudiobooks", code: 0, userInfo: [
      NSLocalizedDescriptionKey: error.localizedDescription,
      "Error": error
    ])
  }
}

extension LCPAudiobooks: LCPStreamingProvider {
  
  public func getPublication() -> Publication? {
    publicationCacheLock.lock()
    defer { publicationCacheLock.unlock() }
    if let publication = cachedPublication {
      return publication
    } else {
      return nil
    }
  }
  
  public func supportsStreaming() -> Bool {
    return true
  }
  
  public func setupStreamingFor(_ player: Any) -> Bool {
    guard let streamingPlayer = player as? StreamingCapablePlayer else {
      return false
    }
    streamingPlayer.setStreamingProvider(self)
    
    publicationCacheLock.lock()
    let hasPublication = cachedPublication != nil
    publicationCacheLock.unlock()
    
    if !hasPublication {
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        self?.loadContentDictionary { _, _ in /* ignore; loader will retry if needed */ }
      }
    }
    
    return true
  }
  
  public func getContainerURL() -> URL? {
    return containerURL
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
    
    // Use license URL if available, otherwise use audiobook URL
    let urlToOpen: AbsoluteURL
    if let licenseUrl = licenseUrl {
      if let fileUrl = FileURL(url: licenseUrl) {
        urlToOpen = fileUrl
      } else if let httpUrl = HTTPURL(url: licenseUrl) {
        urlToOpen = httpUrl
      } else {
        return .failure(NSError(domain: "LCPAudiobooks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid license URL"]))
      }
    } else {
      urlToOpen = audiobookUrl
    }
    
    let result = await self.assetRetriever.retrieve(url: urlToOpen)
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
    let trackIndex: Int
    
    publicationCacheLock.lock()
    defer { publicationCacheLock.unlock() }
    
    if let publication = cachedPublication {
      if let index = publication.readingOrder.firstIndex(where: { link in
        link.href.contains(trackPath) || link.href.hasSuffix(trackPath)
      }) {
        trackIndex = index
      } else {
        let numbers = trackPath.compactMap { Int(String($0)) }
        trackIndex = numbers.first ?? 0
      }
    } else {
      let numbers = trackPath.compactMap { Int(String($0)) }
      trackIndex = numbers.first ?? 0
    }
    
    let fakeUrl = URL(string: "fake://lcp-streaming/track/\(trackIndex)")
    return fakeUrl
  }

  private func publicationURLFromLocalLicense(_ fileUrl: FileURL) -> URL? {
    do {
      let licenseData = try Data(contentsOf: fileUrl.url)
      guard let licenseJson = try JSONSerialization.jsonObject(with: licenseData) as? [String: Any] else {
        TPPErrorLogger.logError(nil, summary: "LCP streaming: license is not valid JSON", metadata: [
          "licenseURL": fileUrl.url.absoluteString
        ])
        return nil
      }

      if let links = licenseJson["links"] as? [[String: Any]] {

        for link in links {
          if let rel = link["rel"] as? String,
             rel == "publication",
             let href = link["href"] as? String,
             let publicationUrl = URL(string: href) {
            return publicationUrl
          }
        }
      }

      TPPErrorLogger.logError(nil, summary: "LCP streaming: publication link not found in license", metadata: [
        "licenseURL": fileUrl.url.absoluteString
      ])
    } catch {
      TPPErrorLogger.logError(error, summary: "Failed to read/parse license file for streaming URL construction", metadata: [
        "licenseURL": fileUrl.url.absoluteString
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
      // Use license URL if available, otherwise use audiobook URL
      let urlToOpen: AbsoluteURL
      if let licenseUrl = licenseUrl {
        if let fileUrl = FileURL(url: licenseUrl) {
          urlToOpen = fileUrl
        } else if let httpUrl = HTTPURL(url: licenseUrl) {
          urlToOpen = httpUrl
        } else {
          completion(NSError(domain: "LCPAudiobooks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid license URL"]))
          return
        }
      } else {
        urlToOpen = audiobookUrl
      }
      
      let result = await self.assetRetriever.retrieve(url: urlToOpen)
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

