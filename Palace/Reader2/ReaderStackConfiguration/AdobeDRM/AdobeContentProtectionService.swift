//
//  AdobeContentProtectionService.swift
//  Palace
//
//  Created by Vladimir Fedorov on 30.06.2021.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

#if FEATURE_DRM_CONNECTOR

import Foundation
import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer

/// Provides information about a publication's content protection and manages user rights.
final class AdobeContentProtectionService: ContentProtectionService {
  var error: Error?
  let context: PublicationServiceContext

  init(context: PublicationServiceContext) {
    self.context = context
    error = nil

    // Remove epubDecodingError reference and check if the container is an AdobeDRMContainer.
    if let adobeContainer = context.container as? AdobeDRMContainer {
      if let drmError = adobeContainer.epubDecodingError {
        error = NSError(
          domain: "Adobe DRM decoding error",
          code: TPPErrorCode.adobeDRMFulfillmentFail.rawValue,
          userInfo: ["AdobeDRMContainer error msg": drmError]
        )
      }
    }
  }

  /// A restricted publication has limited access to its manifest and resources, and can't be rendered in a navigator.
  /// It is typically used for importing publications into the user's bookshelf.
  var isRestricted: Bool {
    context.publication.ref == nil || error != nil
  }

  var rights: UserRights {
    isRestricted ? AllRestrictedUserRights() : UnrestrictedUserRights()
  }

  var name: LocalizedString? {
    LocalizedString.nonlocalized("Adobe DRM")
  }

  var scheme: ContentProtectionScheme {
    .adept
  }
}

#endif
