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
import R2Shared
import ReadiumLCP


@objc class LCPLibraryService: NSObject, DRMLibraryService {
  
  /// Readium licensee file extension
  @objc public let licenseExtension = "lcpl"
  
  private var lcpClient = TPPLCPClient()
  
  /// Readium LCPService
  private var lcpService: LCPService
  
  /// ContentProtection unlocks protected publication, providing a custom `Fetcher`
  lazy var contentProtection: ContentProtection? = lcpService.contentProtection(with: LCPPassphraseAuthenticationService())
  
  /// [LicenseDocument.id: passphrase callback]
  private var authenticationCallbacks: [String: (String?) -> Void] = [:]
  
  override init() {
    self.lcpService = LCPService(client: lcpClient)
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
  func fulfill(_ file: URL) -> Deferred<DRMFulfilledPublication, Error> {
    return deferred { completion in
      self.lcpService.acquirePublication(from: file) { result in
        completion(result
          .map {
            DRMFulfilledPublication(
              localURL: $0.localURL,
              suggestedFilename: $0.suggestedFilename
            )
        }
        .eraseToAnyError()
        )
      }
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
        let errorDescription = (error as? LCPError)?.errorDescription ?? (error as? TPPLicensesServiceError)?.description ?? error?.localizedDescription
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
