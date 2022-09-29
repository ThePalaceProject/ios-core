//
//  EpubSampleFactory.swift
//  Palace
//
//  Created by Maurice Carrier on 8/23/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

@objc class EpubLocationSampleURL: NSObject {
  @objc var url: URL
  
  init(url: URL) {
    self.url = url
  }
}

@objc class EpubSampleWebURL: EpubLocationSampleURL {}

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
        case .failure(let error, _):
          completion(nil, error)
        case .success(let data, _):
  
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
    do {
      try data.write(to: documentDirectory())
    } catch {
      throw error
    }
    return documentDirectory().absoluteURL
  }

  private static func documentDirectory() -> URL {
    let documentDirectory = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    )[0]
    return documentDirectory.appendingPathComponent(samplePath)
  }
}
