import SwiftUI
import ReadiumShared
import ReadiumNavigator

class TPPReaderSettings: ObservableObject {

  /// `fontSize` user property value
  @Published var fontSize: Float = 100

  /// Minimal font size for `fontSize` user property
  private var minFontSize: Float = 100

  /// Maximal font size for `fontSize` user property
  private var maxFontSize: Float = 100

  /// Increase/decrease step
  private var fontSizeStep: Float = 100

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

    // Set font size
    self.fontSize = Float(preferences.fontSize ?? 100)
    self.minFontSize = 75.0
    self.maxFontSize = 250.0
    self.fontSizeStep = 12.5
    screenBrightness = UIScreen.main.brightness

    // Set font family index (map font families to indices)
    self.fontFamilyIndex = mapFontFamilyToIndex(preferences.fontFamily)

    // Set appearance index (theme)
    self.appearanceIndex = mapAppearanceToIndex(preferences.theme)

    if let backgroundColor = preferences.backgroundColor?.uiColor {
      self.backgroundColor = backgroundColor
    }

    if let textColor = preferences.textColor?.uiColor {
      self.textColor = textColor
    }
  }

  /// Convenience init for previews
  init() {
    preferences = EPUBPreferences()
    screenBrightness = UIScreen.main.brightness
  }

  /// Increase `fontSize` user property by `step` value, defined for this property.
  func increaseFontSize() {
    guard canIncreaseFontSize else { return }
    fontSize = min(fontSize + fontSizeStep, maxFontSize)
    preferences.fontSize = Double(fontSize)
    delegate?.updateUserPreferencesStyle()
    savePreferences()
  }

  /// Decrease `fontSize` user property by `step` value, defined for this property.
  func decreaseFontSize() {
    guard canDecreaseFontSize else { return }
    fontSize = max(fontSize - fontSizeStep, minFontSize)
    preferences.fontSize = Double(fontSize)
    delegate?.updateUserPreferencesStyle()
    savePreferences()
  }

  /// Indicates whether `fontSize` property can be increased
  var canIncreaseFontSize: Bool {
    return fontSize + fontSizeStep <= maxFontSize
  }

  /// Indicates whether `fontSize` property can be decreased
  var canDecreaseFontSize: Bool {
    return fontSize - fontSizeStep >= minFontSize
  }

  /// Changes selected appearance index in `preferences`
  /// - Parameter appearanceIndex: index of selected appearance
  func changeAppearance(appearanceIndex: Int) {
    preferences.theme = mapIndexToAppearance(appearanceIndex)
    self.appearanceIndex = appearanceIndex

    if let backgroundColor = preferences.backgroundColor?.uiColor {
      self.backgroundColor = backgroundColor
    }

    if let textColor = preferences.textColor?.uiColor {
      self.textColor = textColor
    }

    delegate?.updateUserPreferencesStyle()
    savePreferences()
  }

  /// Changes selected font family index in `preferences`
  /// - Parameter fontFamilyIndex: index of selected font family
  func changeFontFamily(fontFamilyIndex: Int) {
    preferences.fontFamily = mapIndexToFontFamily(fontFamilyIndex)
    self.fontFamilyIndex = fontFamilyIndex
    delegate?.updateUserPreferencesStyle()
    savePreferences()
  }

  /// Save updated preferences to disk or user settings storage
  private func savePreferences() {
    // Implement saving logic if needed.
  }

  /// Helper function to map font families to indices (you may customize this logic)
  private func mapFontFamilyToIndex(_ fontFamily: FontFamily?) -> Int {
    // Custom mapping logic based on your app's available font families
    return 0
  }

  /// Helper function to map appearance/theme to indices (you may customize this logic)
  private func mapAppearanceToIndex(_ theme: Theme?) -> Int {
    // Custom mapping logic based on available themes
    return 0
  }

  /// Helper function to map an index back to the appropriate `Theme`
  private func mapIndexToAppearance(_ index: Int) -> Theme {
    // Custom mapping logic
    return .light
  }

  /// Helper function to map an index back to the appropriate `FontFamily`
  private func mapIndexToFontFamily(_ index: Int) -> FontFamily? {
    // Custom mapping logic
    return nil
  }
}
