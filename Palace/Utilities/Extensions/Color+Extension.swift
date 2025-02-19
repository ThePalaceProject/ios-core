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
    guard let components = UIColor(self).cgColor.components else { return false }
    let red = components[0] * 299
    let green = components[1] * 587
    let blue = components[2] * 114
    let brightness = (red + green + blue) / 1000
    return brightness < 0.5
  }
}
