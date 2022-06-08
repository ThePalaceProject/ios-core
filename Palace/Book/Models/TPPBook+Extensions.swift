//
//  TPPBook+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 6/7/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

@objc extension TPPBook {
  var bearerToken: String? {
    get {
      UserDefaults.standard.string(forKey: self.identifier)
    }

    set {
      UserDefaults.standard.set(newValue, forKey: self.identifier)
    }
  }
}
