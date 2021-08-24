//
//  AdobeContentProtectionService.swift
//  Palace
//
//  Created by Vladimir Fedorov on 30.06.2021.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

#if FEATURE_DRM_CONNECTOR

import Foundation
import R2Shared
import R2Streamer
import R2Navigator

/// Provides information about a publication's content protection and manages user rights.
final class AdobeContentProtectionService: ContentProtectionService {
  var error: Error?
  let context: PublicationServiceContext

  init(context: PublicationServiceContext) {
    self.context = context
    self.error = nil
    if let adobeFetcher = context.fetcher as? AdobeDRMFetcher {
      if let drmError = adobeFetcher.container.epubDecodingError {
        self.error = NSError(domain: "Adobe DRM decoding error",
                             code: TPPErrorCode.adobeDRMFulfillmentFail.rawValue,
                             userInfo: [
                              "AdobeDRMContainer error msg": drmError
                             ])
      }
    }
  }

  /// A restricted publication has a limited access to its manifest and
  /// resources and can’t be rendered with a Navigator. It is usually
  /// only used to import a publication to the user’s bookshelf.
  var isRestricted: Bool {
    context.publication.ref == nil || error != nil
  }
  
  var rights: UserRights {
    isRestricted ? AllRestrictedUserRights() : UnrestrictedUserRights()
  }
  
  var name: LocalizedString? {
    LocalizedString.nonlocalized("Adobe DRM")
  }

}

#endif
