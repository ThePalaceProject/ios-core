import SwiftUI

extension Color {
  static let colorBackground = Color("ColorBackground")
  static let colorIcon = Color("ColorIcon")
  static let colorIconLogoBlue = Color("ColorIconLogoBlue")
  static let colorInverseLabel = Color("ColorInverseLabel")
  static let onboardingBackground = Color("OnboardingBackground")
  static let colorAudiobookBackground = Color("ColorAudiobookBackground")

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
    let baseUIColor = UIColor(self)
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0

    guard baseUIColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
      return false
    }

    if alpha < 1.0 {
      var bgRed: CGFloat = 0, bgGreen: CGFloat = 0, bgBlue: CGFloat = 0, bgAlpha: CGFloat = 0
      let bgColor = UIColor.systemBackground
      bgColor.getRed(&bgRed, green: &bgGreen, blue: &bgBlue, alpha: &bgAlpha)

      red = red * alpha + bgRed * (1 - alpha)
      green = green * alpha + bgGreen * (1 - alpha)
      blue = blue * alpha + bgBlue * (1 - alpha)
    }

    let brightness = (red * 299 + green * 587 + blue * 114) / 1000

    let maxVal = max(red, green, blue)
    let minVal = min(red, green, blue)
    let saturation: CGFloat = (maxVal == 0) ? 0 : (maxVal - minVal) / maxVal
    let threshold: CGFloat = saturation < 0.1 ? 0.4 : 0.5

    return brightness < threshold
  }
}
