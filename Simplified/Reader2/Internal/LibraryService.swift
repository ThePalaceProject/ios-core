//
//  LibraryService.swift
//  r2-testapp-swift
//
//  Created by Mickaël Menu on 20.02.19.
//
//  Copyright 2019 European Digital Reading Lab. All rights reserved.
//  Licensed to the Readium Foundation under one or more contributor license agreements.
//  Use of this source code is governed by a BSD-style license which is detailed in the
//  LICENSE file present in the project repository where this source code is maintained.
//

import Foundation
import UIKit
import R2Shared
import R2Streamer


final class LibraryService: NSObject, Loggable {

  let publicationServer: PublicationServer

  /// Publications waiting to be added to the PublicationServer (first opening).
  /// publication identifier : data
  var items = [String: (Container, PubParsingCallback)]()

  var drmLibraryServices = [DRMLibraryService]()

  init(publicationServer: PublicationServer) {
    self.publicationServer = publicationServer

    #if LCP
    drmLibraryServices.append(LCPLibraryService())
    #endif
  }

  /// Complementary parsing of the publication.
  /// Will parse Nav/ncx + mo (files that are possibly encrypted)
  /// using the DRM object of the publication.container.
  func loadDRM(for book: NYPLBook, completion: @escaping (CancellableResult<DRM?>) -> Void) {

    guard let filename = book.fileName, let (container, parsingCallback) = items[filename] else {
      completion(.success(nil))
      return
    }

    guard let drm = container.drm else {
      // No DRM, so the parsing callback can be directly called.
      do {
        try parsingCallback(nil)
        completion(.success(nil))
      } catch {
        completion(.failure(error))
      }
      return
    }

    guard let drmService = drmLibraryServices.first(where: { $0.brand == drm.brand }) else {
      // TODO: SIMPLY-2650
      //delegate?.libraryService(self, presentError: LibraryError.drmNotSupported(drm.brand))
      completion(.success(nil))
      return
    }

    let url = URL(fileURLWithPath: container.rootFile.rootPath)
    drmService.loadPublication(at: url, drm: drm) { result in
      switch result {
      case .success(let drm):
        do {
          /// Update container.drm to drm and parse the remaining elements.
          try parsingCallback(drm)
          completion(.success(drm))
        } catch {
          completion(.failure(error))
        }
      default:
        completion(result)
      }
    }
  }

  func preparePresentation(of publication: Publication, book: NYPLBook, with container: Container) {
    // If the book is a webpub, it means it is loaded remotely from a URL, and it doesn't need to be added to the publication server.
    if publication.format != .webpub {
      publicationServer.removeAll()
      guard let bookURLStr = book.url?.absoluteString else {
        log(.error, "Book with ID \(book.identifier ?? "''") has no usable URL")
        return
      }
      do {
        try publicationServer.add(publication, with: container, at: bookURLStr)
      } catch {
        log(.error, error)
      }
    }
  }

  func parsePublication(for book: NYPLBook) -> PubBox? {
    guard let url = book.url else {
      return nil
    }

    return parsePublication(at: url)
  }

  func parsePublication(atPath path: String) -> PubBox? {
    let path: String = {
      // Relative to Documents/ or the App bundle?
      if !path.hasPrefix("/") {
        let filesMgr = FileManager.default

        let documents = try! FileManager.default.url(
          for: .documentDirectory,
          in: .userDomainMask,
          appropriateFor: nil,
          create: true
        )

        // try in sandbox
        let documentPath = documents.appendingPathComponent(path).path
        if filesMgr.fileExists(atPath: documentPath) {
          return documentPath
        }

        // try in app bundle
        if let bundlePath = Bundle.main.path(forResource: path, ofType: nil),
          filesMgr.fileExists(atPath: bundlePath)
        {
          return bundlePath
        }
      }

      return path
    }()

    return parsePublication(at: URL(fileURLWithPath: path))
  }

  func parsePublication(at url: URL) -> PubBox? {
    do {
      guard let (pubBox, parsingCallback) = try Publication.parse(at: url) else {
        return nil
      }
      let (publication, container) = pubBox
      items[url.lastPathComponent] = (container, parsingCallback)
      return (publication, container)

    } catch {
      log(.error, "Error parsing publication at '\(url.absoluteString)': \(error.localizedDescription)")
      return nil
    }
  }

}

