//
//  AdobeDRMError.swift
//  Palace
//
//  Created by Vladimir Fedorov on 14.10.2021.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation

#if FEATURE_DRM_CONNECTOR

enum AdobeDRMError: LocalizedError {
  
  /// Indicates the item license has expired
  case expiredDisplayUntilDate
  
  public var errorDescription: String? {
    switch self {
    case .expiredDisplayUntilDate: return NSLocalizedString("The book license has expired.", comment: "Expired license warning")
    }
  }
}

#endif
