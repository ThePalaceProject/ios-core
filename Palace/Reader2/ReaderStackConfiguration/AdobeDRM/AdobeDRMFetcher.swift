//
//  AdobeDRMFetcher.swift
//  The Palace Project
//
//  Created by Vladimir Fedorov on 10.02.2021.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

import Foundation
import R2Shared

#if FEATURE_DRM_CONNECTOR

/// Adobe DRM fetcher
/// Decrypts .epub contents data
class AdobeDRMFetcher: Fetcher {
  
  /// AdobeDRMContainer calls Adobe DRM software
  let container: AdobeDRMContainer
  
  /// ArchiveFetcher for the publication
  let fetcher: Fetcher
  
  /// Adobe DRM Fetcher initializer
  /// - Parameters:
  ///   - url: Publication URL
  ///   - fetcher: ArchiveFetcher for the publication
  ///   - encryptionData: `META-INF/encryption.xml` file contents
  init(url: URL, fetcher: Fetcher, encryptionData: Data) throws {
    self.container = AdobeDRMContainer(url: url, encryptionData: encryptionData)
    // Check if the book can still be displayed
    if let displayUntilDate = container.displayUntilDate, displayUntilDate < Date() {
      throw AdobeDRMFetcherError.expiredDisplayUntilDate
    }
    self.fetcher = fetcher
    self.links = fetcher.links
  }
  
  /// Known resources available in the medium, such as file paths on the file system.
  var links: [Link]
  
  /// Get resource such as content file by its link.
  ///
  /// `AdobeDRMFetcher` `get` function open .epub resources using the `fetcher` passed to `init`.
  ///  After resource is found and its data is read, AdobeDRMContainer decodes the resource data.
  ///
  /// - Parameter link: Resource link (URL of content HREF)
  /// - Returns: Decrypted `Resource` object; `DataResource` in case of success or `FailureResource` otherwise.
  func get(_ link: Link) -> Resource {
    do {
      let resource = fetcher.get(link)
      let encryptedData = try resource.read().get()
      let href = link.href.starts(with: "/") ? String(link.href.dropFirst()) : link.href // remove leading /
      let data = container.decode(encryptedData, at: href)
      if let error = container.epubDecodingError, error == AdobeDRMContainerExpiredLicenseError {
        return FailureResource(link: link, error: .forbidden(AdobeDRMFetcherError.expiredDisplayUntilDate))
      }
      return DataResource(link: link, data: data)
    } catch {
      return FailureResource(link: link, error: .other(error))
    }
  }
  
  func close() {
    fetcher.close()
  }
}

#endif
