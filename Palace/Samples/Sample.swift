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

    /// Fetch the sample bytes.
    ///
    /// `async` (PP-5301): both consumers are `@MainActor`
    /// (`AudiobookSamplePlayer`, and `EpubSampleFactory` on behalf of
    /// `BookCellModel`), so the completion they used to pass inherited
    /// main-actor isolation while the network layer delivered off it. Each had
    /// hopped some arms and not others. Awaiting resumes on the caller's actor,
    /// so there are no arms to get wrong.
    func fetchSample() async -> NYPLResult<Data>
}

extension Sample {
    var needsDownload: Bool { type.needsDownload }

    func fetchSample() async -> NYPLResult<Data> {
        await AppContainer.production().networkExecutor.fetchResult(from: url, useTokenIfAvailable: false)
    }
}
