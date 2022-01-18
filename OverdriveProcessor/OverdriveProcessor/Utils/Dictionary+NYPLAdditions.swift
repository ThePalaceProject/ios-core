//
//  Dictionary+NYPLAdditions.swift
//  OverdriveProcessor
//
//  Created by Ettore Pasquini on 8/13/20.
//  Copyright © 2020 NYPL. All rights reserved.
//

import Foundation

public extension Dictionary where Key: StringProtocol {

  /// Converts all keys to be all lowercase. If the dictionary included the
  /// same key with the only difference being the capitalization, the last
  /// key-value pair present in the dictionary will be lost.
  mutating func formLowercaseKeys() {
    let originalKeys = self.keys
    for key in originalKeys {
      if let lowercaseKey = key.lowercased() as? Key {
        self[lowercaseKey] = self.removeValue(forKey: key)
      }
    }
  }
}
