//
//  EpubSampleFactory.swift
//  Palace
//
//  Created by Maurice Carrier on 8/23/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

// MARK: - EpubLocationSampleURL

@objc class EpubLocationSampleURL: NSObject {
  @objc var url: URL

  init(url: URL) {
    self.url = url
  }
}

// MARK: - EpubSampleWebURL

@objc class EpubSampleWebURL: EpubLocationSampleURL {}

// MARK: - EpubSampleFactory

@objc class EpubSampleFactory: NSObject {
  private static let samplePath = "TestApp.epub"

  @objc static func createSample(book: TPPBook, completion: @escaping (EpubLocationSampleURL?, Error?) -> Void) {
    guard let epubSample = book.sample as? EpubSample
    else {
      completion(nil, SamplePlayerError.noSampleAvailable)
      return
    }

    if epubSample.type.needsDownload {
      epubSample.fetchSample { result in
        switch result {
        case let .failure(error, _):
          completion(nil, error)
        case let .success(data, _):
          do {
            guard let location = try save(data: data) else {
              completion(nil, SamplePlayerError.fileSaveFailed(nil))
              return
            }

            let epubLocationURL = EpubLocationSampleURL(url: location)
            DispatchQueue.main.async {
              completion(epubLocationURL, nil)
            }
          } catch {
            completion(nil, error)
          }
        }
      }
    } else {
      let webURL = EpubSampleWebURL(url: epubSample.url)
      completion(webURL, nil)
    }
  }

  private static func save(data: Data) throws -> URL? {
    let url = documentDirectory()
    do {
      // Create parent directory if it doesn't exist
      let parentDirectory = url.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true, attributes: nil)

      try data.write(to: url)
      Log.info(#file, "Successfully saved sample EPUB to: \(url.path)")
    } catch {
      Log.error(#file, "Failed to save sample EPUB: \(error.localizedDescription)")
      throw error
    }
    return url.absoluteURL
  }

  private static func documentDirectory() -> URL {
    let documentDirectory = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    )[0]

    // Create samples subdirectory to avoid root directory access issues
    let samplesDirectory = documentDirectory.appendingPathComponent("Samples")
    try? FileManager.default.createDirectory(at: samplesDirectory, withIntermediateDirectories: true, attributes: nil)

    return samplesDirectory.appendingPathComponent(samplePath)
  }
}
