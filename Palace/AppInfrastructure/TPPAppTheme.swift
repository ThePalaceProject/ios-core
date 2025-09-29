@objcMembers final class TPPAppTheme: NSObject {
  private enum NYPLAppThemeColor: String {
    case red
    case pink
    case purple
    case deepPurple = "lightpurple"
    case indigo
    case blue
    case lightBlue = "lightblue"
    case cyan
    case teal
    case green
    case amber
    case orange
    case deepOrange = "lightorange"
    case brown
    case grey
    case blueGrey = "bluegrey"
    case black
  }

  class func themeColorFromString(name: String) -> UIColor {
    if let theme = NYPLAppThemeColor(rawValue: name.lowercased()) {
      return colorFromHex(hex(theme))
    } else {
      Log.error(#file, "Given theme color is not supported: \(name)")
      return TPPConfiguration.compatiblePrimaryColor()
    }
  }

  private class func colorFromHex(_ hex: Int) -> UIColor {
    UIColor(
      red: CGFloat((hex & 0xFF0000) >> 16) / 255,
      green: CGFloat((hex & 0xFF00) >> 8) / 255,
      blue: CGFloat(hex & 0xFF) / 255,
      alpha: 1.0
    )
  }

  // Currently using 'primary-dark' variant of
  // Android Color Palette 500 series. https://material.io/tools/color/
  // An updated palette should update hex, but leave the enum values.
  private class func hex(_ theme: NYPLAppThemeColor) -> Int {
    switch theme {
    case .red:
      0xB9000D
    case .pink:
      0xB0003A
    case .purple:
      0x6A0080
    case .deepPurple:
      0x320B86
    case .indigo:
      0x002984
    case .blue:
      0x0069C0
    case .lightBlue:
      0x007AC1
    case .cyan:
      0x008BA3
    case .teal:
      0x087F23
    case .green:
      0x087F23
    case .amber:
      0xC79100
    case .orange:
      0xC66900
    case .deepOrange:
      0xC41C00
    case .brown:
      0x4B2C20
    case .grey:
      0x707070
    case .blueGrey:
      0x34515E
    case .black:
      0x000000
    }
  }
}
