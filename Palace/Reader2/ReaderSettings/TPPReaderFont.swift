//
//  TPPReaderFont.swift
//  Palace
//
//  Created by Vladimir Fedorov on 15.02.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI

enum TPPReaderFont: String, CaseIterable, Identifiable {
  case original = "Original" // Readium2 shows default book font for index 0
  case sansSerif = "Helvetica"
  case serif = "Georgia"
  case dyslexic = "OpenDyslexic"
  
  typealias DisplayStrings = Strings.TPPReaderFont

  var id: String {
    rawValue
  }
  
  /// Font size for preview
  var previewSize: CGFloat {
    switch self {
    case .dyslexic: return 20.0
    default: return 24.0
    }
  }
  
  /// Property index returns non-optional element index
  var propertyIndex: Int {
    guard let index = TPPReaderFont.allCases.firstIndex(of: self) else {
      return 0 // default book font
    }
    return index
  }
  
  /// UIFont object for TPPReaderFont element
  private var uiFont: UIFont? {
    switch self {
    case .dyslexic: return UIFont(name: "OpenDyslexic3", size: previewSize) // "OpenDyslexic" in Readium2
    default: return UIFont(name: rawValue, size: previewSize)
    }
  }
  
  /// SwiftUI Font structure for TPPReaderFont element
  var font: Font? {
    if let uiFont = uiFont {
      return Font(uiFont: uiFont)
    }
    return nil
  }
  
  /// Accessibility text for accessibility labels
  var accessibilityText: String {
    switch self {
    case .original: return DisplayStrings.original
    case .sansSerif: return DisplayStrings.sans
    case .serif: return DisplayStrings.serif
    case .dyslexic: return DisplayStrings.dyslexic
    }
  }
}
