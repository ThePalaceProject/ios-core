//
//  ReaderError.swift
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

enum ReaderError: LocalizedError {
  case formatNotSupported
  case epubNotValid

  var errorDescription: String? {
    switch self {
    case .formatNotSupported:
      Strings.Error.formatNotSupportedError
    case .epubNotValid:
      Strings.Error.epubNotValidError
    }
  }
}
