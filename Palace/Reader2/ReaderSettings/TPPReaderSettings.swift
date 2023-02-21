//
//  TPPReaderSettings.swift
//  Palace
//
//  Created by Vladimir Fedorov on 02.02.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI
import R2Shared
import R2Navigator

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
  
  private(set) var userSettings: UserSettings
  private var delegate: TPPReaderSettingsDelegate?
  
  init(userSettings: UserSettings, delegate: TPPReaderSettingsDelegate) {
    self.userSettings = userSettings
    self.delegate = delegate

    // Set font size variation
    if let settingsFontSize = userSettings.userProperties.getProperty(reference: ReadiumCSSReference.fontSize.rawValue) as? Incrementable {
      settingsFontSize.max = 250.0
      settingsFontSize.min = 75.0
      settingsFontSize.step = 12.5

      self.fontSize = settingsFontSize.value
      self.minFontSize = settingsFontSize.min
      self.maxFontSize = settingsFontSize.max
      self.fontSizeStep = settingsFontSize.step
    }
    
    if let fontFamily = userSettings.userProperties.getProperty(reference: ReadiumCSSReference.fontFamily.rawValue) as? Enumerable {
      self.fontFamilyIndex = fontFamily.index
    }
    
    if let appearance = userSettings.userProperties.getProperty(reference: ReadiumCSSReference.appearance.rawValue) as? Enumerable {
      self.appearanceIndex = appearance.index
      let colors = TPPAssociatedColors.colors(for: appearance)
      backgroundColor = colors.backgroundColor
      textColor = colors.textColor
    }
    
    screenBrightness = UIScreen.main.brightness
  }
  
  /// Convenience init for previews
  init() {
    userSettings = UserSettings()
    screenBrightness = UIScreen.main.brightness
  }
  
  /// Increase `fontSize` user property by `step` value, defined for this property.
  func increaseFontSize() {
    if let settingsFontSize = userSettings.userProperties.getProperty(reference: ReadiumCSSReference.fontSize.rawValue) as? Incrementable {
      settingsFontSize.increment()
      fontSize = settingsFontSize.value
      delegate?.updateUserSettingsStyle()
      userSettings.save()
    }
  }
  
  /// Decrease `fontSize` user property by `step` value, defined for this property.
  func decreaseFontSize() {
    if let settingsFontSize = userSettings.userProperties.getProperty(reference: ReadiumCSSReference.fontSize.rawValue) as? Incrementable {
      settingsFontSize.decrement()
      fontSize = settingsFontSize.value
      delegate?.updateUserSettingsStyle()
      userSettings.save()
    }
  }
  
  /// Indicates whether `fontSize` property can be increased
  var canIncreaseFontSize: Bool {
    fontSize + fontSizeStep < maxFontSize
  }
  
  /// Indicates whether `fontSize` property can be decreased
  var canDecreaseFontSize: Bool {
    fontSize - fontSizeStep > minFontSize
  }
  
  /// Changes selected appearance index in `userSettings`
  /// - Parameter appearanceIndex: index of selected appearance
  func changeAppearance(appearanceIndex: Int) {
    if let appearance = userSettings.userProperties.getProperty(reference: ReadiumCSSReference.appearance.rawValue) as? Enumerable {
      appearance.index = appearanceIndex
      self.appearanceIndex = appearanceIndex
      delegate?.updateUserSettingsStyle()
      delegate?.setUIColor(for: appearance)
      let colors = TPPAssociatedColors.colors(for: appearance)
      backgroundColor = colors.backgroundColor
      textColor = colors.textColor
      userSettings.save()
    }
  }
  
  /// Changes selected font family indes in `userSettings`
  /// - Parameter fontFamilyIndex: index of selected font family
  func changeFontFamily(fontFamilyIndex: Int) {
    if let fontFamily = userSettings.userProperties.getProperty(reference: ReadiumCSSReference.fontFamily.rawValue) as? Enumerable,
       let fontOverride = userSettings.userProperties.getProperty(reference: ReadiumCSSReference.fontOverride.rawValue) as? Switchable {
      fontFamily.index = fontFamilyIndex
      self.fontFamilyIndex = fontFamilyIndex
      if fontFamily.index != 0 {
        fontOverride.on = true
      } else {
        fontOverride.on = false
      }
      delegate?.updateUserSettingsStyle()
      userSettings.save()
    }
  }
}
