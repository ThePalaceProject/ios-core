//
//  LibraryServiceError.swift
//  The Palace Project
//
//  Created by Mickaël Menu on 12.06.19.
//
//  Copyright 2019 European Digital Reading Lab. All rights reserved.
//  Licensed to the Readium Foundation under one or more contributor license agreements.
//  Use of this source code is governed by a BSD-style license which is detailed in the
//  LICENSE file present in the project repository where this source code is maintained.
//

import Foundation
import R2Shared

enum LibraryServiceError: LocalizedError {
  
  case invalidBook
  case openFailed(Error)
  
  var errorDescription: String? {
    switch self {
    case .invalidBook:
      return Strings.Error.invalidBookError
    case .openFailed(let error):
      var errorDescription = error.localizedDescription
      // Publication opening may fail due to DRM error
      // Trying to get DRM error description
      if let openingError = error as? Publication.OpeningError,
         let drmErrorDescription = openingError.drmErrorDescription {
        errorDescription = drmErrorDescription
      }
      return String(format: Strings.Error.openFailedError, errorDescription)
    }
  }
  
}
