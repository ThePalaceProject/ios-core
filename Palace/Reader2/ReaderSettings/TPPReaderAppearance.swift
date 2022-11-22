//
//  TPPReaderAppearance.swift
//  Palace
//
//  Created by Vladimir Fedorov on 17.02.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

enum TPPReaderAppearance: Int,  CaseIterable, Identifiable {
  case blackOnWhite, blackOnSepia, whiteOnBlack
  
  var id: Int {
    rawValue
  }
  
  var propertyIndex: Int {
    rawValue
  }
  
  var associatedColors: TPPAppearanceColors {
    switch self {
    case .blackOnWhite: return .blackOnWhiteColors
    case .blackOnSepia: return .blackOnSepiaColors
    case .whiteOnBlack: return .whiteOnBlackColors
    }
  }
  
  var accessibilityText: String {
    switch self {
    case .blackOnWhite: return NSLocalizedString("BlackOnWhiteText", comment: "BlackOnWhiteText")
    case .blackOnSepia: return NSLocalizedString("BlackOnSepiaText", comment: "BlackOnSepiaText")
    case .whiteOnBlack: return NSLocalizedString("WhiteOnBlackText", comment: "WhiteOnBlackText")
    }
  }
}
