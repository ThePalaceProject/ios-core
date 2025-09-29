//
//  TPPReaderAppearance.swift
//  Palace
//
//  Created by Vladimir Fedorov on 17.02.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

enum TPPReaderAppearance: Int, CaseIterable, Identifiable {
  case blackOnWhite
  case blackOnSepia
  case whiteOnBlack

  typealias DisplayStrings = Strings.TPPReaderAppearance

  var id: Int {
    rawValue
  }

  var propertyIndex: Int {
    rawValue
  }

  var associatedColors: TPPAppearanceColors {
    switch self {
    case .blackOnWhite: .blackOnWhiteColors
    case .blackOnSepia: .blackOnSepiaColors
    case .whiteOnBlack: .whiteOnBlackColors
    }
  }

  var accessibilityText: String {
    switch self {
    case .blackOnWhite: DisplayStrings.blackOnWhiteText
    case .blackOnSepia: DisplayStrings.blackOnSepiaText
    case .whiteOnBlack: DisplayStrings.whiteOnBlackText
    }
  }
}
