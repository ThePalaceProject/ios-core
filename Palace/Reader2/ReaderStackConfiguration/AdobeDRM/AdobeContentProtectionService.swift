//
//  AdobeContentProtectionService.swift
//  Palace
//
//  Created by Vladimir Fedorov on 30.06.2021.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

#if FEATURE_DRM_CONNECTOR

import Foundation
import ReadiumShared
import ReadiumStreamer
import ReadiumNavigator

/// Provides information about a publication's content protection and manages user rights.
final class AdobeContentProtectionService: ContentProtectionService {
  var error: Error?
  let context: PublicationServiceContext

  init(context: PublicationServiceContext) {
    self.context = context
    self.error = nil
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
