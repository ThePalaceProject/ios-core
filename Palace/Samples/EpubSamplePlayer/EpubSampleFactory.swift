//
//  EpubSampleFactory.swift
//  Palace
//
//  Created by Maurice Carrier on 8/23/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging
import PalaceBookModel

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

// `@unchecked Sendable` restated: Swift requires a subclass to re-declare an
// inherited `@unchecked Sendable` conformance. Same write-once-then-read `url`
// invariant as the `EpubLocationSampleURL` superclass — no added mutable state.
@objc class EpubSampleWebURL: EpubLocationSampleURL, @unchecked Sendable {}

class EpubSampleFactory: NSObject {
    private static let samplePath = "TestApp.epub"

    /// Prepare a playable location for `book`'s sample.
    ///
    /// `@MainActor` and `async` (PP-5301). Both callers are `@MainActor`
    /// (`BookCellModel`, `BookDetailViewModel`), so the completion they passed
    /// inherited main-actor isolation — and this method delivered the success
    /// case through `DispatchQueue.main.async` while handing every failure
    /// straight back on the network executor's own thread. `BookCellModel`'s
    /// closure then read `self.isLoading` and presented a view controller from
    /// there, which is the PP-5299 crash class on a sample whose download
    /// fails. Returning instead of calling back puts every arm on the caller's
    /// actor, so the asymmetry cannot be written.
    @MainActor
    static func createSample(book: TPPBook) async throws -> EpubLocationSampleURL {
        guard let epubSample = book.sample as? EpubSample else {
            throw SamplePlayerError.noSampleAvailable
        }

        guard epubSample.type.needsDownload else {
            return EpubSampleWebURL(url: epubSample.url)
        }

        switch await epubSample.fetchSample() {
        case .failure(let error, _):
            throw error
        case .success(let data, _):
            guard let location = try save(data: data) else {
                throw SamplePlayerError.fileSaveFailed(nil)
            }
            return EpubLocationSampleURL(url: location)
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
