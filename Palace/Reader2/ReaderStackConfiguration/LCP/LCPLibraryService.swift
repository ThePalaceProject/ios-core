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
import ReadiumShared
import ReadiumLCP
import ReadiumAdapterLCPSQLite


@objc class LCPLibraryService: NSObject, DRMLibraryService {

  /// Readium licensee file extension
  @objc public let licenseExtension = "lcpl"
  
  private var lcpClient = TPPLCPClient()

  /// ContentProtection unlocks protected publication, providing a custom `Fetcher`
  lazy var contentProtection: ContentProtection? = lcpService.contentProtection(with: LCPPassphraseAuthenticationService())
  
  /// [LicenseDocument.id: passphrase callback]
  private var authenticationCallbacks: [String: (String?) -> Void] = [:]

  private lazy var lcpService: LCPService = {
    do {
      let licenseRepo = try LCPSQLiteLicenseRepository()
      let passphraseRepo = try LCPSQLitePassphraseRepository()

      return LCPService(
        client: TPPLCPClient(),
        licenseRepository: licenseRepo,
        passphraseRepository: passphraseRepo,
        assetRetriever: AssetRetriever(httpClient: DefaultHTTPClient()),
        httpClient: DefaultHTTPClient()
      )
    } catch {
      fatalError("Failed to initialize LCPService: \(error)")
    }
  }()

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
    guard let fileURL = file.fileURL else {
      throw LCPError.unknown(nil)
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
