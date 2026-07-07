//
//  EpubSampleFactory.swift
//  Palace
//
//  Created by Maurice Carrier on 8/23/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging

/// Swift 6 `complete` — `@unchecked Sendable` invariant: `url` is set once at
/// `init` and is not mutated afterward anywhere in the codebase (the `@objc var` is
/// retained only for ObjC key-value access). Write-once-then-read confinement lets
/// the value cross the `@Sendable` sample-download completion into the main-actor
/// `completion` call. Documented invariant.
@objc class EpubLocationSampleURL: NSObject, @unchecked Sendable {
    @objc var url: URL

    init(url: URL) {
        self.url = url
    }
}

@objc class EpubSampleWebURL: EpubLocationSampleURL {}

/// Carries the non-`Sendable` `createSample` completion across the `@Sendable`
/// `fetchSample` / `main.async` boundaries. Invoked exactly once. Mirrors
/// `ImageCompletionBox`.
private final class SampleCompletionBox: @unchecked Sendable {
    let call: (EpubLocationSampleURL?, Error?) -> Void
    init(_ call: @escaping (EpubLocationSampleURL?, Error?) -> Void) { self.call = call }
}

@objc class EpubSampleFactory: NSObject {
    private static let samplePath = "TestApp.epub"

    @objc static func createSample(book: TPPBook, completion: @escaping (EpubLocationSampleURL?, Error?) -> Void) {
        // Box the non-`Sendable` completion so it can cross the `@Sendable`
        // `fetchSample` / `main.async` boundaries below; invoked exactly once.
        let completionBox = SampleCompletionBox(completion)
        guard let epubSample = book.sample as? EpubSample
        else {
            completionBox.call(nil, SamplePlayerError.noSampleAvailable)
            return
        }

        if epubSample.type.needsDownload {
            epubSample.fetchSample { result in
                switch result {
                case .failure(let error, _):
                    completionBox.call(nil, error)
                case .success(let data, _):

                    do {
                        guard let location = try save(data: data) else {
                            completionBox.call(nil, SamplePlayerError.fileSaveFailed(nil))
                            return
                        }

                        let epubLocationURL = EpubLocationSampleURL(url: location)
                        DispatchQueue.main.async {
                            completionBox.call(epubLocationURL, nil)
                        }
                    } catch {
                        completionBox.call(nil, error)
                    }
                }
            }
        } else {
            let webURL = EpubSampleWebURL(url: epubSample.url)
            completionBox.call(webURL, nil)
        }
    }

    private static func save(data: Data) throws -> URL? {
        let url = documentDirectory()
        do {
            // Create parent directory if it doesn't exist
            let parentDirectory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true, attributes: nil)
            parentDirectory.excludeFromBackup()

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
        samplesDirectory.excludeFromBackup()

        return samplesDirectory.appendingPathComponent(samplePath)
    }
}
