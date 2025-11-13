import SwiftUI
import ReadiumShared
import ReadiumNavigator

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
    self.fontSize = Float(preferences.fontSize ?? 0.5)
    screenBrightness = UIScreen.main.brightness

    // Set font and appearance based on initial preferences
    self.fontFamilyIndex = TPPReaderSettings.mapFontFamilyToIndex(preferences.fontFamily)
    self.appearanceIndex = TPPReaderSettings.mapAppearanceToIndex(preferences.theme)

    // Ensure publisherStyles is disabled to prevent line-height conflicts
    self.preferences.publisherStyles = false
    
    updateColors(for: TPPReaderAppearance(rawValue: appearanceIndex) ?? .blackOnWhite)
  }

  // Convenience initializer for previews
  init() {
    preferences = EPUBPreferences()
    screenBrightness = UIScreen.main.brightness
  }

  // Font size increase method
  func increaseFontSize() {
    guard canIncreaseFontSize else { return }
    fontSize = min(fontSize + fontSizeStep, maxFontSize)
    preferences.fontSize = Double(fontSize)
    // Ensure publisherStyles stays disabled to prevent line-height conflicts
    preferences.publisherStyles = false
    delegate?.updateUserPreferencesStyle(for: preferences)
    savePreferences()
  }

  // Font size decrease method
  func decreaseFontSize() {
    guard canDecreaseFontSize else { return }
    fontSize = max(fontSize - fontSizeStep, minFontSize)
    preferences.fontSize = Double(fontSize)
    // Ensure publisherStyles stays disabled to prevent line-height conflicts
    preferences.publisherStyles = false
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
       let preferences = try? JSONDecoder().decode(EPUBPreferences.self, from: data) {
      return preferences
    }
    return EPUBPreferences()
  }

  // Mapping helper for font families
  static func mapFontFamilyToIndex(_ fontFamily: FontFamily?) -> Int {
    switch fontFamily {
    case .some(.sansSerif): return TPPReaderFont.sansSerif.propertyIndex
    case .some(.serif): return TPPReaderFont.serif.propertyIndex
    case .some(.openDyslexic): return TPPReaderFont.dyslexic.propertyIndex
    default: return TPPReaderFont.original.propertyIndex
    }
  }

  // Mapping helper for appearance themes
  static func mapAppearanceToIndex(_ theme: Theme?) -> Int {
    switch theme {
    case .dark: return TPPReaderAppearance.whiteOnBlack.propertyIndex
    case .sepia: return TPPReaderAppearance.blackOnSepia.propertyIndex
    default: return TPPReaderAppearance.blackOnWhite.propertyIndex
    }
  }

  static func mapIndexToAppearance(_ index: Int) -> Theme {
    switch index {
    case TPPReaderAppearance.whiteOnBlack.propertyIndex: return .dark
    case TPPReaderAppearance.blackOnSepia.propertyIndex: return .sepia
    default: return .light
    }
  }

  static func mapIndexToFontFamily(_ index: Int) -> FontFamily? {
    switch index {
    case TPPReaderFont.sansSerif.propertyIndex: return .sansSerif
    case TPPReaderFont.serif.propertyIndex: return .serif
    case TPPReaderFont.dyslexic.propertyIndex: return .openDyslexic
    default: return nil
    }
  }
}

// Non-isolated helper for loading reader preferences outside of MainActor contexts
func TPPReaderPreferencesLoad() -> EPUBPreferences {
  let key = "TPPReaderSettings"
  var defaultPreferences: EPUBPreferences
  
  if let data = UserDefaults.standard.data(forKey: key),
     let preferences = try? JSONDecoder().decode(EPUBPreferences.self, from: data) {
    defaultPreferences = preferences
  } else {
    defaultPreferences = EPUBPreferences()
  }
  
  if defaultPreferences.theme == nil {
    defaultPreferences.theme = .light
  }
  
  if defaultPreferences.backgroundColor == nil || defaultPreferences.textColor == nil {
    let defaultColors = TPPAppearanceColors.blackOnWhiteColors
    defaultPreferences.backgroundColor = ReadiumNavigator.Color(color: Color(defaultColors.backgroundColor))
    defaultPreferences.textColor = ReadiumNavigator.Color(color: Color(defaultColors.textColor))
  }
  
  defaultPreferences.publisherStyles = false
  
  return defaultPreferences
}
