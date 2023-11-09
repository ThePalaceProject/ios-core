//
//  UserProfileDocument+Links.swift
//  Palace
//
//  Created by Vladimir Fedorov on 08.11.2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

extension UserProfileDocument {
  enum LinkRelation: String {
    case deviceRegistration = "http://palaceproject.io/terms/deviceRegistration"
  }
  
  func linksWith(_ rel: LinkRelation) -> [Link] {
    links?.filter { $0.rel == rel.rawValue } ?? []
  }
}
