//
//  LCPAudiobooks.swift
//  The Palace Project
//
//  Created by Vladimir Fedorov on 16.11.2020.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

#if LCP

import Foundation
import PalaceAudiobookToolkit
import ReadiumLCP
import ReadiumShared
import ReadiumStreamer

@objc class LCPAudiobooks: NSObject {
  private static let expectedAcquisitionType = "application/vnd.readium.lcp.license.v1.0+json"

  private let audiobookUrl: AbsoluteURL
  private let licenseUrl: URL?
  private let assetRetriever: AssetRetriever
  private let publicationOpener: PublicationOpener
  private let httpClient: DefaultHTTPClient

  private var cachedPublication: Publication?
  private let publicationCacheLock = NSLock()
  private var currentPrefetchTask: Task<Void, Never>?

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
    assetRetriever = AssetRetriever(httpClient: httpClient)

    guard let contentProtection = lcpService.contentProtection else {
      return nil
    }

    let parser = DefaultPublicationParser(
      httpClient: httpClient,
      assetRetriever: assetRetriever,
      pdfFactory: DefaultPDFDocumentFactory()
    )

    publicationOpener = PublicationOpener(
      parser: parser,
      contentProtections: [contentProtection]
    )
  }

  @objc func contentDictionary(completion: @escaping (_ json: NSDictionary?, _ error: NSError?) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
      self.loadContentDictionary { json, error in
        DispatchQueue.main.async {
          completion(json, error)
        }
      }
    }
  }

  private func loadContentDictionary(completion: @escaping (_ json: NSDictionary?, _ error: NSError?) -> Void) {
    publicationCacheLock.lock()
    currentPrefetchTask?.cancel()
    publicationCacheLock.unlock()

    let task = Task { [weak self] in
      guard let self else {
        return
      }
      if Task.isCancelled {
        return
      }

      var urlToOpen: AbsoluteURL = audiobookUrl
      if let licenseUrl {
        if let fileUrl = FileURL(url: licenseUrl) {
          urlToOpen = fileUrl
        } else if let httpUrl = HTTPURL(url: licenseUrl) {
          urlToOpen = httpUrl
        } else {
          completion(
            nil,
            NSError(domain: "LCPAudiobooks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid license URL"])
          )
          return
        }
      }

      let result = await assetRetriever.retrieve(url: urlToOpen)

      switch result {
      case let .success(asset):
        if Task.isCancelled {
          return
        }

        var credentials: String? = nil
        if let licenseUrl = licenseUrl, licenseUrl.isFileURL {
          credentials = try? String(contentsOf: licenseUrl)
        }

        let result = await publicationOpener.open(
          asset: asset,
          allowUserInteraction: true,
          credentials: credentials,
          sender: nil
        )

        switch result {
        case let .success(publication):
          if Task.isCancelled {
            return
          }
          publicationCacheLock.lock()
          cachedPublication = publication
          publicationCacheLock.unlock()

          if let jsonManifestString = publication.jsonManifest, let jsonData = jsonManifestString.data(using: .utf8),
             let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? NSDictionary
          {
            completion(jsonObject, nil)
          } else {
            let links = publication.readingOrder.map { link in
              let hrefString = String(describing: link.href)
              let typeString = link.mediaType.map { String(describing: $0) } ?? "audio/mpeg"
              return [
                "href": hrefString,
                "type": typeString,
              ]
            }
            let minimal: [String: Any] = [
              "metadata": [
                "identifier": UUID().uuidString,
                "title": String(describing: publication.metadata.title),
              ],
              "readingOrder": links,
            ]
            completion(minimal as NSDictionary, nil)
          }
        case let .failure(error):
          completion(nil, LCPAudiobooks.nsError(for: error))
        }

      case let .failure(error):
        completion(nil, LCPAudiobooks.nsError(for: error))
      }

      publicationCacheLock.lock()
      if currentPrefetchTask?.isCancelled == true {
        currentPrefetchTask = nil
      }
      publicationCacheLock.unlock()
    }

    publicationCacheLock.lock()
    currentPrefetchTask = task
    publicationCacheLock.unlock()
  }

  /// Check if the book is LCP audiobook
  /// - Parameter book: audiobook
  /// - Returns: `true` if the book is an LCP DRM protected audiobook, `false` otherwise
  @objc static func canOpenBook(_ book: TPPBook) -> Bool {
    guard let defaultAcquisition = book.defaultAcquisition else {
      return false
    }
    return book.defaultBookContentType == .audiobook && defaultAcquisition.type == expectedAcquisitionType
  }

  /// Creates an NSError for Objective-C code
  /// - Parameter error: Error object
  /// - Returns: NSError object
  private static func nsError(for error: Error) -> NSError {
    NSError(domain: "Palace.LCPAudiobooks", code: 0, userInfo: [
      NSLocalizedDescriptionKey: error.localizedDescription,
      "Error": error,
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
    true
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
      DispatchQueue.global(qos: .userInteractive).async { [weak self] in
        self?.loadContentDictionary { _, error in
          if let error = error {
            Log.error(#file, "Failed to load LCP publication for streaming: \(error)")
          } else {
            Log.info(#file, "Successfully loaded LCP publication for streaming")

            DispatchQueue.main.async {
              streamingPlayer.publicationDidLoad()
            }
          }
        }
      }
    }

    return true
  }
}

// MARK: - Cached manifest access

extension LCPAudiobooks {
  /// Returns the cached content dictionary if the publication has already been opened.
  /// This avoids re-opening the asset and enables immediate UI presentation.
  func cachedContentDictionary() -> NSDictionary? {
    publicationCacheLock.lock()
    let publication = cachedPublication
    publicationCacheLock.unlock()

    guard let publication, let jsonManifestString = publication.jsonManifest,
          let jsonData = jsonManifestString.data(using: .utf8)
    else {
      return nil
    }

    if let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? NSDictionary {
      return jsonObject
    }
    return nil
  }

  func startPrefetch() {
    DispatchQueue.global(qos: .userInteractive).async { [weak self] in
      self?.loadContentDictionary { _, _ in
      }
    }
  }

  func decrypt(url: URL, to resultUrl: URL, completion: @escaping (Error?) -> Void) {
    if let publication = getPublication() {
      decryptWithPublication(publication, url: url, to: resultUrl, completion: completion)
    } else {
      Task {
        let result = await self.assetRetriever.retrieve(url: audiobookUrl)
        switch result {
        case let .success(asset):
          let publicationResult = await publicationOpener.open(asset: asset, allowUserInteraction: false, sender: nil)
          switch publicationResult {
          case let .success(publication):
            publicationCacheLock.lock()
            cachedPublication = publication
            publicationCacheLock.unlock()

            self.decryptWithPublication(publication, url: url, to: resultUrl, completion: completion)

          case let .failure(error):
            completion(error)
          }
        case let .failure(error):
          completion(error)
        }
      }
    }
  }

  private func decryptWithPublication(
    _ publication: Publication,
    url: URL,
    to resultUrl: URL,
    completion: @escaping (Error?) -> Void
  ) {
    if let resource = publication.getResource(at: url.path) {
      Task {
        do {
          let data = try await resource.read().get()
          try data.write(to: resultUrl, options: .atomic)
          DispatchQueue.main.async {
            completion(nil)
          }
        } catch {
          DispatchQueue.main.async {
            completion(error)
          }
        }
      }
    } else {
      completion(NSError(
        domain: "AudiobookResourceError",
        code: 404,
        userInfo: [NSLocalizedDescriptionKey: "Resource not found at path: \(url.path)"]
      ))
    }
  }

  func cancelPrefetch() {
    publicationCacheLock.lock()
    currentPrefetchTask?.cancel()
    currentPrefetchTask = nil
    publicationCacheLock.unlock()
  }

  /// Release all held resources for the current publication and cancel any background work
  func releaseResources() {
    cancelPrefetch()
    publicationCacheLock.lock()
    cachedPublication = nil
    publicationCacheLock.unlock()
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
