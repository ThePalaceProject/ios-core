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

                self._lcpService = LCPService(
                    client: TPPLCPClient(),
                    licenseRepository: licenseRepo,
                    passphraseRepository: passphraseRepo,
                    assetRetriever: AssetRetriever(httpClient: LCPCredentialStrippingHTTPClient()),
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
