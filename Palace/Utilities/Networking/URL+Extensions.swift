//
//  URL+Extensions.swift
//  Palace
//
//  Created by Vladimir Fedorov on 12/05/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

extension URL {
  func replacingScheme(with scheme: String) -> URL {
    guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
      return self
    }
    components.scheme = scheme
    return components.url ?? self
  }
}
