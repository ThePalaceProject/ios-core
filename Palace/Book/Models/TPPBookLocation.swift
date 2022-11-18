//
//  TPPBookLocation.swift
//  Palace
//
//  Created by Vladimir Fedorov on 09.11.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

typealias TPPBookLocationData = [String: Any]

extension TPPBookLocationData {
  func string(for key: TPPBookLocationKey) -> String? {
    return self[key.rawValue] as? String
  }
}

enum TPPBookLocationKey: String {
  case locationString = "locationString"
  case renderer = "renderer"
}

@objcMembers
class TPPBookLocation: NSObject {
  
  /// Due to differences in how different renderers (e.g. Readium, RMSDK, et cetera) want to handle
  /// location information, it is necessary to store location information in an unstructured manner.
  /// When creating an instance of this class, |locationString| is the renderer-specific data and
  /// `renderer` is a string that uniquely identifies the renderer that generated it. When loading a
  /// location, renderers can inspect `renderer` to ensure the location string they're about to use is
  /// compatible with their underlying systems.
  var locationString: String
  
  // Renderer
  var renderer: String
  
  init?(locationString: String, renderer: String) {
    self.locationString = locationString
    self.renderer = renderer
  }
  init?(dictionary: [String: Any]) {
    let locationData = dictionary as TPPBookLocationData
    guard let locationString = locationData.string(for: .locationString),
          let renderer = locationData.string(for: .renderer)
    else {
      return nil
    }
    self.locationString = locationString
    self.renderer = renderer
  }
  var dictionaryRepresentation: [String: Any] {
    return [
      TPPBookLocationKey.locationString.rawValue: self.locationString,
      TPPBookLocationKey.renderer.rawValue: self.renderer
    ]
  }
}
