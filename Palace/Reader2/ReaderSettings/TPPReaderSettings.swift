import ReadiumNavigator
import ReadiumShared
import SwiftUI

// MARK: - TPPReaderSettings

@MainActor
class TPPReaderSettings: ObservableObject {
  private static let preferencesKey = "TPPReaderSettings"

  @Published var fontSize: Float = 1.0
  private var minFontSize: Float = 1.0
  private var maxFontSize: Float = 5.0
  private var fontSizeStep: Float = 0.5

  @Published var fontFamilyIndex: Int = 0
  @Published var appearanceIndex: Int = 0

  @Published var screenBrightness: Double {
    didSet {
      if UIScreen.main.brightness != screenBrightness {
        UIScreen.main.brightness = screenBrightness
      }
    }
  }

  @Published var textColor: UIColor = .black
  @Published var backgroundColor: UIColor = .white

  private(set) var preferences: EPUBPreferences
  private var delegate: TPPReaderSettingsDelegate?

  init(preferences: EPUBPreferences, delegate: TPPReaderSettingsDelegate) {
    self.preferences = preferences
    self.delegate = delegate

    // Initialize font size
    fontSize = Float(preferences.fontSize ?? 0.5)
    screenBrightness = UIScreen.main.brightness

    // Set font and appearance based on initial preferences
    fontFamilyIndex = TPPReaderSettings.mapFontFamilyToIndex(preferences.fontFamily)
    appearanceIndex = TPPReaderSettings.mapAppearanceToIndex(preferences.theme)

    updateColors(for: TPPReaderAppearance(rawValue: appearanceIndex) ?? .blackOnWhite)
  }

  // Convenience initializer for previews
  init() {
    preferences = EPUBPreferences()
    screenBrightness = UIScreen.main.brightness
  }

  // Font size increase method
  func increaseFontSize() {
    guard canIncreaseFontSize else {
      return
    }
    fontSize = min(fontSize + fontSizeStep, maxFontSize)
    preferences.fontSize = Double(fontSize)
    delegate?.updateUserPreferencesStyle(for: preferences)
    savePreferences()
  }

  // Font size decrease method
  func decreaseFontSize() {
    guard canDecreaseFontSize else {
      return
    }
    fontSize = max(fontSize - fontSizeStep, minFontSize)
    preferences.fontSize = Double(fontSize)
    delegate?.updateUserPreferencesStyle(for: preferences)
    savePreferences()
  }

  var canIncreaseFontSize: Bool {
    fontSize + fontSizeStep <= maxFontSize
  }

  var canDecreaseFontSize: Bool {
    fontSize - fontSizeStep >= minFontSize
  }

  func changeAppearance(appearanceIndex: Int) {
    self.appearanceIndex = appearanceIndex
    preferences.theme = TPPReaderSettings.mapIndexToAppearance(appearanceIndex)

    updateColors(for: TPPReaderAppearance(rawValue: appearanceIndex) ?? .blackOnWhite)
    delegate?.updateUserPreferencesStyle(for: preferences)
    savePreferences()
  }

  func changeFontFamily(fontFamilyIndex: Int) {
    self.fontFamilyIndex = fontFamilyIndex
    preferences.fontFamily = TPPReaderSettings.mapIndexToFontFamily(fontFamilyIndex)
    delegate?.updateUserPreferencesStyle(for: preferences)
    savePreferences()
  }

  private func updateColors(for appearance: TPPReaderAppearance) {
    let colors = appearance.associatedColors
    backgroundColor = colors.backgroundColor
    textColor = colors.textColor
    preferences.backgroundColor = ReadiumNavigator.Color(color: Color(backgroundColor))
    preferences.textColor = ReadiumNavigator.Color(color: Color(textColor))
  }

  private func savePreferences() {
    if let data = try? JSONEncoder().encode(preferences) {
      UserDefaults.standard.set(data, forKey: TPPReaderSettings.preferencesKey)
    }
  }

  static func loadPreferences() -> EPUBPreferences {
    if let data = UserDefaults.standard.data(forKey: TPPReaderSettings.preferencesKey),
       let preferences = try? JSONDecoder().decode(EPUBPreferences.self, from: data)
    {
      return preferences
    }
    return EPUBPreferences()
  }

  // Mapping helper for font families
  static func mapFontFamilyToIndex(_ fontFamily: FontFamily?) -> Int {
    switch fontFamily {
    case .some(.sansSerif): TPPReaderFont.sansSerif.propertyIndex
    case .some(.serif): TPPReaderFont.serif.propertyIndex
    case .some(.openDyslexic): TPPReaderFont.dyslexic.propertyIndex
    default: TPPReaderFont.original.propertyIndex
    }
  }

  // Mapping helper for appearance themes
  static func mapAppearanceToIndex(_ theme: Theme?) -> Int {
    switch theme {
    case .dark: TPPReaderAppearance.whiteOnBlack.propertyIndex
    case .sepia: TPPReaderAppearance.blackOnSepia.propertyIndex
    default: TPPReaderAppearance.blackOnWhite.propertyIndex
    }
  }

  static func mapIndexToAppearance(_ index: Int) -> Theme {
    switch index {
    case TPPReaderAppearance.whiteOnBlack.propertyIndex: .dark
    case TPPReaderAppearance.blackOnSepia.propertyIndex: .sepia
    default: .light
    }
  }

  static func mapIndexToFontFamily(_ index: Int) -> FontFamily? {
    switch index {
    case TPPReaderFont.sansSerif.propertyIndex: .sansSerif
    case TPPReaderFont.serif.propertyIndex: .serif
    case TPPReaderFont.dyslexic.propertyIndex: .openDyslexic
    default: nil
    }
  }
}

// Non-isolated helper for loading reader preferences outside of MainActor contexts
func TPPReaderPreferencesLoad() -> EPUBPreferences {
  let key = "TPPReaderSettings"
  if let data = UserDefaults.standard.data(forKey: key),
     let preferences = try? JSONDecoder().decode(EPUBPreferences.self, from: data)
  {
    return preferences
  }
  return EPUBPreferences()
}
