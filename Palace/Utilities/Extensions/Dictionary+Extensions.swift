//
//  Dictionary+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 6/16/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

extension Dictionary {
  func mapKeys<T>(_ transform: (Key) throws -> T) rethrows -> Dictionary<T, Value> {
    var dictionary = Dictionary<T, Value>()
    for (key, value) in self {
      dictionary[try transform(key)] = value
    }
    return dictionary
  }
}

extension Dictionary where Key == String, Value: Any {
  
  /// Pretty prints the JSON dictionary
  func prettyPrintJSON() {
    do {
      let jsonData = try JSONSerialization.data(withJSONObject: self, options: .prettyPrinted)
      if let jsonString = String(data: jsonData, encoding: .utf8) {
        print(jsonString)
      }
    } catch {
      print("Failed to pretty print JSON: \(error)")
    }
  }
}
