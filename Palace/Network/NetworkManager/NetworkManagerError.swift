//
//  NetworkManagerError.swift
//  Palace
//
//  Created by Maurice Carrier on 10/15/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation

enum NetworkManagerError: Error, Equatable {
  case offline
  case serverError(Error)
  case internalError(TPPErrorCode)
  case invalidURL
  case invalidData
  
  static func == (lhs: NetworkManagerError, rhs: NetworkManagerError) -> Bool {
    switch (lhs, rhs) {
    case let (.serverError(a), .serverError(b)):
      return a.localizedDescription == b.localizedDescription
    case let (.internalError(a), .internalError(b)):
      return a == b
    default:
      return lhs == rhs
    }
  }
}
