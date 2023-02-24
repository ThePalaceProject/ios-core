//
//  Sample.swift
//  Palace
//
//  Created by Maurice Carrier on 8/14/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

enum SampleType: String {
  case contentTypeEpubZip = "application/epub+zip"
  case overdriveEbook = "text/html"
  case openAccessAudiobook = "application/audiobook+json"
  case overdriveAudiobook = "application/json"

  var needsDownload: Bool {
    switch self {
    case .contentTypeEpubZip, .overdriveAudiobook:
      return true
    default:
      return false
    }
  }
}

protocol Sample {
  var url: URL { get }
  var type: SampleType { get }
  func fetchSample(completion: @escaping (NYPLResult<Data>) -> Void)
}

extension Sample {
  var needsDownload: Bool {
    switch type {
    case .contentTypeEpubZip, .overdriveAudiobook:
      return true
    default:
      return false
    }
  }

  func fetchSample(completion: @escaping (NYPLResult<Data>) -> Void) {
    let _ = TPPNetworkExecutor.shared.GET(url) { result in
        completion(result)
    }
  }
}
