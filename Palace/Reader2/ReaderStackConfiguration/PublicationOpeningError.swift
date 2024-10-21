//
//  PublicationOpeningError.swift
//  Palace
//
//  Created by Vladimir Fedorov on 15.10.2021.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation
import ReadiumShared

// Extending R2Shared opening error to get underlying error message from Adobe DRM
//extension Publication.OpeningError {
//  var drmErrorDescription: String? {
//    switch self {
//    case .forbidden(let error):
//      return error?.localizedDescription
//    default:
//      return nil
//    }
//  }
//}
