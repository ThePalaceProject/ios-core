import SwiftUI

extension Color {
  static let colorBackground = Color("ColorBackground")
  static let colorIcon = Color("ColorIcon")
  static let colorIconLogoBlue = Color("ColorIconLogoBlue")
  static let colorInverseLabel = Color("ColorInverseLabel")
  static let onboardingBackground = Color("OnboardingBackground")

  static let palaceBlueBase = Color("PalaceBlueBase")
  static let palaceBlueLight = Color("PalaceBlueLight")

  static let palaceErrorBase = Color("PalaceErrorBase")
  static let palaceErrorDark = Color("PalaceErrorDark")
  static let palaceErrorLight = Color("PalaceErrorLight")
  static let palaceErrorMedium = Color("PalaceErrorMedium")

  static let palaceGraysBlack = Color("PalaceGraysBlack")
  static let palaceGraysDark = Color("PalaceGraysDark")
  static let palaceGraysLight = Color("PalaceGraysLight")
  static let palaceGraysWhite = Color("PalaceGraysWhite")

  static let palaceRed = Color("PalaceRed")

  static let palaceSuccessBase = Color("PalaceSuccessBase")
  static let palaceSuccessDark = Color("PalaceSuccessDark")
  static let palaceSuccessLight = Color("PalaceSuccessLight")
  static let palaceSuccessMedium = Color("PalaceSuccessMedium")
}


extension Color {
  var isDark: Bool {
    let uiColor = UIColor(self)
    guard let components = uiColor.cgColor.components else { return false }

    let red, green, blue: CGFloat

    switch components.count {
    case 2: // Grayscale (white/black, etc.)
      red = components[0]
      green = components[0]
      blue = components[0]
    case 3: // RGB
      red = components[0]
      green = components[1]
      blue = components[2]
    case 4: // RGBA
      red = components[0]
      green = components[1]
      blue = components[2]
    default:
      return false // Unexpected case, assume non-dark color
    }

    let brightness = (red * 299 + green * 587 + blue * 114) / 1000
    return brightness < 0.5
  }
}
