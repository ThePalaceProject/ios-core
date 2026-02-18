import Foundation
import ReadiumShared
import ReadiumNavigator
import UIKit

struct TPPAppearanceColors {
  let backgroundColor: UIColor
  let backgroundMediaOverlayHighlightColor: UIColor
  let textColor: UIColor
  let navigationColor: UIColor
  let foregroundColor: UIColor
  let selectedForegroundColor: UIColor
  let tintColor: UIColor

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

  // Black text on sepia background set of colors
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

  // White text on black background set of colors
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

  /// `EPUBPreferences` object from Readium 3 API containing user appearance settings
  var preferences: EPUBPreferences?

  /// Colors for the selected appearance based on Readium 3 `EPUBPreferences`.
  var appearanceColors: TPPAppearanceColors {
    guard let theme = preferences?.theme else {
      return .blackOnWhiteColors // Fallback to default if no theme is set
    }
    return TPPAssociatedColors.colors(for: theme)
  }

  /// Get associated colors for a specific theme setting from `EPUBPreferences`.
  /// - Parameter theme: The selected theme from the new `EPUBPreferences` API.
  /// - Returns: A set of colors based on the theme.
  static func colors(for theme: Theme) -> TPPAppearanceColors {
    switch theme {
    case .sepia:
      return .blackOnSepiaColors
    case .dark:
      return .whiteOnBlackColors
    default:
      return .blackOnWhiteColors
    }
  }
}
