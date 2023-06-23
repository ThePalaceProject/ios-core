//
//  BookDownloadError.swift
//  Palace
//
//  Created by Maurice Carrier on 6/19/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

enum BookDownloadError: Error {
  case invalidURL
  case networkError(Error)
  case fileSystemError(Error)
}
