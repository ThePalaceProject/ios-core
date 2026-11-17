//
//  LCPLibraryService.swift
//
//  Created by Mickaël Menu on 01.02.19.
//
//  Copyright 2019 Readium Foundation. All rights reserved.
//  Use of this source code is governed by a BSD-style license which is detailed
//  in the LICENSE file present in the project repository where this source code is maintained.
//

#if LCP

import Foundation
import UIKit
import PalaceAudiobookToolkit
import ReadiumShared
import ReadiumLCP

// Swift 6 `complete`: `@unchecked Sendable`. This type is exposed as the shared
// global `lcpService` (see `TPPLCPClient.swift`) which is read from multiple
// concurrency domains (the Audiobooks LCP path in `LCPAudiobooks`, the reader
// content-protection path). INVARIANT — every stored member is either immutable
// (`licenseExtension`, `lcpClient`, `serviceQueue`, `serviceLock`) or guarded:
// the lazily-built `_lcpService` and `_contentProtection` are both initialized
// once behind `serviceQueue.sync` + `serviceLock`, so no unsynchronized mutable
// state crosses threads. `TPPLCPClient` is itself lock-backed (its own
// `contextQueue`). The parallel precedent is `AdobeDRMService` (lock-backed
// `@unchecked Sendable`). The test subclass `SpyLCPLibraryService` overrides
// `fulfill` only and adds no cross-thread mutable state.
@objc class LCPLibraryService: NSObject, DRMLibraryService, @unchecked Sendable {

    /// Readium licensee file extension
    @objc public let licenseExtension = "lcpl"

    private let lcpClient = TPPLCPClient()
    private var _lcpService: LCPService?
    private var _contentProtection: ContentProtection?

    /// The one client every read of a streamed LCP archive goes through.
    ///
    /// Shared, not merely configured alike in two places: the range store holds
    /// an exclusive advisory lock on its directory, so a second client for the
    /// same archive is refused and reads through for the rest of the session,
    /// and which of the two loses is a race. The retriever handed to LCPService
    /// and the parser inside LCPAudiobooks therefore use this instance.
    private var _archiveReadClient: PartialArchiveCachingHTTPClient?
    private let serviceQueue = DispatchQueue(label: "com.palace.LCPLibraryService.serviceQueue", qos: .userInitiated)
    private let serviceLock = NSLock()

    /// ContentProtection unlocks protected publication, providing a custom `Fetcher`.
    ///
    /// Init-once behind `serviceQueue.sync` so concurrent reads (reader open +
    /// audiobook open) share a single instance without racing the lazy backing
    /// store (a plain `lazy var` is not concurrency-safe under `complete`).
    var contentProtection: ContentProtection? {
        serviceQueue.sync {
            if _contentProtection == nil {
                _contentProtection = lcpService(locked: true)?.contentProtection(with: LCPPassphraseAuthenticationService())
            }
            return _contentProtection
        }
    }

    /// - Parameter locked: `true` when the caller already holds `serviceQueue`,
    ///   matching `lcpService(locked:)` so neither re-enters `serviceQueue.sync`.
    private func archiveReadClient(locked: Bool) -> PartialArchiveCachingHTTPClient {
        let build: () -> PartialArchiveCachingHTTPClient = {
            if self._archiveReadClient == nil {
                self._archiveReadClient = PartialArchiveCachingHTTPClient(
                    upstream: LCPCredentialStrippingHTTPClient(),
                    storeFactory: LCPAudiobooks.makeArchiveRangeStore
                )
            }
            // Assigned immediately above when nil, so this cannot be nil here.
            return self._archiveReadClient!
        }
        return locked ? build() : serviceQueue.sync(execute: build)
    }

    /// Shared with `LCPAudiobooks` — see the note on `_archiveReadClient`.
    var archiveReadClient: PartialArchiveCachingHTTPClient {
        archiveReadClient(locked: false)
    }

    private var lcpService: LCPService? {
        lcpService(locked: false)
    }

    /// - Parameter locked: `true` when the caller already holds `serviceQueue`
    ///   (the `contentProtection` accessor), to avoid re-entrant `serviceQueue.sync`
    ///   deadlock; `false` for direct callers, which acquire the queue here.
    private func lcpService(locked: Bool) -> LCPService? {
        let build: () -> LCPService? = {
            if self._lcpService == nil {
                self.serviceLock.lock()
                defer { self.serviceLock.unlock() }

                // Readium 3.8.0+: license/passphrase storage moved from the
                // deprecated SQLite repositories to the Keychain repositories
                // (more secure, survives reinstall, iCloud-syncable). Existing
                // patrons' SQLite data is carried over once by
                // `LCPKeychainMigration` (run at launch); a license that hasn't
                // migrated yet simply re-validates from its stored `.lcpl`.
                let licenseRepo = LCPKeychainLicenseRepository()
                let passphraseRepo = LCPKeychainPassphraseRepository()

                // The retriever handed to LCPService is the one its ContentProtection uses
                // to fetch the publication a streaming licence names, and the container it
                // returns is what every archive read for playback goes through:
                // LCPService.contentProtection -> LCPContentProtection.openLicense ->
                // assetRetriever.retrieve(link: licenseDocument.publicationLink).
                //
                // So the byte-range cache belongs here. Wrapping only the client inside
                // LCPAudiobooks reaches the local .lcpl licence read and not one archive
                // byte, which is why retaining ranges there changed nothing on device.
                // Requests without a Range header pass straight through, so LCP EPUB and
                // PDF fulfilment are unaffected (PP-5367).
                self._lcpService = LCPService(
                    client: TPPLCPClient(),
                    licenseRepository: licenseRepo,
                    passphraseRepository: passphraseRepo,
                    assetRetriever: AssetRetriever(httpClient: self.archiveReadClient(locked: true)),
                    httpClient: LCPCredentialStrippingHTTPClient()
                )
            }
            return self._lcpService
        }
        return locked ? build() : serviceQueue.sync(execute: build)
    }

    override init() {
        super.init()
    }

    /// Returns whether this DRM can fulfill the given file into a protected publication.
    /// - Parameter file: file URL
    /// - Returns: `true` if file contains LCP DRM license information.
    func canFulfill(_ file: URL) -> Bool {
        return file.pathExtension.lowercased() == licenseExtension
    }

    /// Fulfill LCP license publication.
    /// - Parameter file: LCP license file.
    /// - Returns: fulfilled publication as `Deferred` (`CancellableReesult` interenally) object.
    func fulfill(_ file: URL) async throws -> DRMFulfilledPublication {
        guard let lcpService = lcpService else {
            throw LCPError.unknown(NSError(domain: "LCPLibraryService", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "LCPService not initialized"
            ]))
        }

        guard let fileURL = file.fileURL else {
            throw LCPError.unknown(NSError(domain: "LCPLibraryService", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "Invalid file URL"
            ]))
        }

        // Verify file exists before attempting to acquire - Readium may hang on non-existent files
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw LCPError.unknown(NSError(domain: "LCPLibraryService", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "License file does not exist at path: \(fileURL.path)"
            ]))
        }

        let licenseSource = LicenseDocumentSource.file(fileURL)
        let result = await lcpService.acquirePublication(from: licenseSource)
        switch result {
        case .success(let publication):
            return DRMFulfilledPublication(
                localURL: publication.localURL.url,
                suggestedFilename: publication.suggestedFilename
            )
        case .failure(let error):
            throw error
        }
    }

    /// Fulfill LCP license publication
    /// This function was added for compatibility with Objective-C NYPLMyBooksDownloadCenter.
    /// - Parameters:
    ///   - file: LCP license file.
    ///   - completion: Completion is called after a publication was downloaded or an error received.
    ///   - localUrl: Downloaded publication URL.
    ///   - downloadTask: `URLSessionDownloadTask` that downloaded the publication.
    ///   - error: `NSError` if any.
    @objc func fulfill(_ file: URL, progress: @escaping (_ progress: Double) -> Void, completion: @escaping (_ localUrl: URL?, _ error: NSError?) -> Void) -> URLSessionDownloadTask? {
        guard let lcpService = lcpService else {
            let error = NSError(domain: "LCPLibraryService", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "LCPService not initialized"
            ])
            completion(nil, error)
            return nil
        }
        return TPPLicensesService().acquirePublication(from: file) { progressValue in
            progress(progressValue)
        } completion: { localUrl, error in
            guard error == nil else {
                let domain = "LCP fulfillment error"
                let code = TPPErrorCode.lcpDRMFulfillmentFail.rawValue
                let errorDescription = (error as? LCPError)?.localizedDescription ?? (error as? TPPLicensesServiceError)?.description ?? error?.localizedDescription
                let nsError = NSError(domain: domain, code: code, userInfo: [
                    NSLocalizedDescriptionKey: errorDescription as Any
                ])
                completion(nil, nsError)
                return
            }
            completion(localUrl, nil)
        }
    }

    /// Decrypts data passed to LCP decryptor.
    /// - Parameter data: Encrypted data.
    /// - Returns: Decrypted data.
    ///
    /// Encrypted data must be a valid block of AES-encrypted data, othervise LCP decryptor crashes the app.
    func decrypt(data: Data) -> Data? {
        lcpClient.decrypt(data: data)
    }
}

#endif
