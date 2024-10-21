//
//  AdobeDRMFetcher.swift
//  The Palace Project
//
//  Created by Vladimir Fedorov on 10.02.2021.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

import Foundation
import ReadiumShared

#if FEATURE_DRM_CONNECTOR

/// Adobe DRM container fetcher.
/// This fetcher decrypts .epub contents data by using an Adobe DRM container.
class AdobeDRMFetcher: Container {

  /// Adobe DRM Container to interact with Adobe DRM software
  let drmContainer: AdobeDRMContainer

  /// Original container that holds the publication data
  let container: Container

  /// Adobe DRM Fetcher initializer
  /// - Parameters:
  ///   - url: The URL of the publication
  ///   - container: The original container (replacing `fetcher`)
  ///   - encryptionData: The contents of the `META-INF/encryption.xml` file
  init(url: URL, container: Container, encryptionData: Data) throws {
    self.drmContainer = AdobeDRMContainer(url: url, encryptionData: encryptionData)
    // Check if the book can still be displayed
    if let displayUntilDate = drmContainer.displayUntilDate, displayUntilDate < Date() {
      throw AdobeDRMFetcherError.expiredDisplayUntilDate
    }
    self.container = container
  }

  /// The source URL for the container
  var sourceURL: AbsoluteURL? {
    return container.sourceURL
  }

  /// List of all the container entries
  var entries: Set<AnyURL> {
    return container.entries
  }

  /// Fetches the resource by decrypting it using Adobe DRM.
  /// - Parameter url: The resource URL
  /// - Returns: A decrypted `Resource` or a failure in case of error
  subscript(url: any URLConvertible) -> Resource? {
    guard let resource = container[url] else {
      return FailureResource(error: .access(.fileSystem(.fileNotFound(nil))))
    }

    // Create a placeholder resource to return for now
    let failureResource = FailureResource(error: .access(.fileSystem(.forbidden(AdobeDRMFetcherError.expiredDisplayUntilDate))))

    // Launch a task to handle the DRM decryption asynchronously
    Task {
        let drmResult = await resource.read()

        // Handle the DRM result
        switch drmResult {
        case .success(let decryptedData):
          // Check if any DRM error occurred (e.g., expired license)
          if let error = drmContainer.epubDecodingError, error == AdobeDRMContainerExpiredLicenseError {
            return FailureResource(error: .access(.fileSystem(.forbidden(AdobeDRMFetcherError.expiredDisplayUntilDate)))) as Resource
          }
          // Return the decrypted data as a DataResource
          return DataResource(data: decryptedData)
        case .failure(let readError):
          // Handle DRM decryption failure
          return FailureResource(error: .access(.fileSystem(.io(readError))))
        }
    }

    // Return a placeholder failure resource for now, while the Task executes
    return failureResource
  }

  /// Close the fetcher and all resources
  func close() {
    container.close()
  }
}

#endif
