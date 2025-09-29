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
import ReadiumShared

enum LibraryServiceError: LocalizedError {
  case invalidBook
  case cancelled
  case openFailed(Error)

  var errorDescription: String? {
    switch self {
    case .invalidBook:
      Strings.Error.invalidBookError
    case let .openFailed(error):
      String(format: Strings.Error.openFailedError, error.localizedDescription)
    case .cancelled:
      nil
    }
  }
}
