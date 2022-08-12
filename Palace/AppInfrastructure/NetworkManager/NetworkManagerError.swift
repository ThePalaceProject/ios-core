//
//  NetworkManagerError.swift
//  Palace
//
//  Created by Maurice Carrier on 8/10/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

enum NetworkManagerError: Error {
  case previewFetchFailed
  case previewDecodeFailed
  case internalError
}
