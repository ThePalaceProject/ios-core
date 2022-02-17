//
//  TPPAssociatedColors.swift
//  Palace
//
//  Created by Vladimir Fedorov on 17.02.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import R2Shared
import R2Navigator
import UIKit

struct TPPAppearanceColors {
  let backgroundColor: UIColor
  let backgroundMediaOverlayHighlightColor: UIColor
  let textColor: UIColor
  let navigationColor: UIColor
  let foregroundColor: UIColor
  let selectedForegroundColor: UIColor
  let tintColor: UIColor
  
  /// Black text on white background set of colors
  static var blackOnWhiteColors: TPPAppearanceColors {
    TPPAppearanceColors(
      backgroundColor: TPPConfiguration.readerBackgroundColor(),
      backgroundMediaOverlayHighlightColor: TPPConfiguration.backgroundMediaOverlayHighlightColor(),
      textColor: .black,
      navigationColor: .black,
      foregroundColor: .black,
      selectedForegroundColor: .white,
      tintColor: .darkGray
    )
  }

  /// Black text on sepia background set of colors
  static var blackOnSepiaColors: TPPAppearanceColors {
    TPPAppearanceColors(
      backgroundColor: TPPConfiguration.readerBackgroundSepiaColor(),
      backgroundMediaOverlayHighlightColor: TPPConfiguration.backgroundMediaOverlayHighlightSepiaColor(),
      textColor: .black,
      navigationColor: .black,
      foregroundColor: .black,
      selectedForegroundColor: .white,
      tintColor: .darkGray
    )
  }

  /// White text on black background set of colors
  static var whiteOnBlackColors: TPPAppearanceColors {
    TPPAppearanceColors(
      backgroundColor: TPPConfiguration.readerBackgroundDarkColor(),
      backgroundMediaOverlayHighlightColor: TPPConfiguration.backgroundMediaOverlayHighlightDarkColor(),
      textColor: .white,
      navigationColor: .white,
      foregroundColor: .white,
      selectedForegroundColor: .black,
      tintColor: .white
    )
  }

}

class TPPAssociatedColors {

  static let shared = TPPAssociatedColors()
  
  /// epubNavigaor property, set this one when user opens a book
  var userSettings: UserSettings?
  
  /// Colors for selected appearance
  var appearanceColors: TPPAppearanceColors {
    let appearance = userSettings?.userProperties.getProperty(reference: ReadiumCSSReference.appearance.rawValue)
    return TPPAssociatedColors.colors(for: appearance)
  }
  
  /// Get associated colors for a specific appearance setting.
  /// - parameter appearance: The selected appearance.
  /// - Returns: A tuple with a background color and a text color.
  static func colors(for appearance: UserProperty? = nil) -> TPPAppearanceColors {
    if let appearance = appearance {
      switch appearance.toString() {
      case "readium-sepia-on":
        return .blackOnSepiaColors
      case "readium-night-on":
        return .whiteOnBlackColors
      default:
        return .blackOnWhiteColors
      }
    }
    return .blackOnWhiteColors
  }

}
