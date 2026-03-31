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
    case overdriveWeb = "text/html"
    case openAccessAudiobook = "application/audiobook+json"
    case overdriveAudiobookWaveFile = "audio/x-ms-wma"
    case overdriveAudiobookMpeg = "audio/mpeg"

    var needsDownload: Bool {
        switch self {
        case .contentTypeEpubZip, .overdriveAudiobookMpeg, .overdriveAudiobookWaveFile:
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
    var needsDownload: Bool { type.needsDownload }

    func fetchSample(networkExecutor: TPPNetworkExecutor = .shared, completion: @escaping (NYPLResult<Data>) -> Void) {
        _ = networkExecutor.GET(url, useTokenIfAvailable: false) { result in
            completion(result)
        }
    }
}
