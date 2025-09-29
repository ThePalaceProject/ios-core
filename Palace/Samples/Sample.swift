//
//  Sample.swift
//  Palace
//
//  Created by Maurice Carrier on 8/14/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

// MARK: - SampleType

enum SampleType: String {
  case contentTypeEpubZip = "application/epub+zip"
  case overdriveWeb = "text/html"
  case openAccessAudiobook = "application/audiobook+json"
  case overdriveAudiobookWaveFile = "audio/x-ms-wma"
  case overdriveAudiobookMpeg = "audio/mpeg"

  var needsDownload: Bool {
    switch self {
    case .contentTypeEpubZip, .overdriveAudiobookMpeg, .overdriveAudiobookWaveFile:
      true
    default:
      false
    }
  }
}

// MARK: - Sample

protocol Sample {
  var url: URL { get }
  var type: SampleType { get }
  func fetchSample(completion: @escaping (NYPLResult<Data>) -> Void)
}

extension Sample {
  var needsDownload: Bool { type.needsDownload }

  func fetchSample(completion: @escaping (NYPLResult<Data>) -> Void) {
    _ = TPPNetworkExecutor.shared.GET(url, useTokenIfAvailable: false) { result in
      completion(result)
    }
  }
}
