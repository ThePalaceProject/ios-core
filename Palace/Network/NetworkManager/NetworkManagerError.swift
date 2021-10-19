//
//  NetworkManagerError.swift
//  Palace
//
//  Created by Maurice Carrier on 10/15/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation

enum NetworkManagerError: Error {
  case offline
  case serverError(Error)
  case internalError(TPPErrorCode)
  case invalidURL
  case invalidData
}
