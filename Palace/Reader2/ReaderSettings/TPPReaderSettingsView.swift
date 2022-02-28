//
//  TPPReaderSettingsView.swift
//  Palace
//
//  Created by Vladimir Fedorov on 02.02.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI
import R2Shared
import R2Navigator
import CryptoKit

/// Height of settings view controls
fileprivate let buttonHeight = 50.0

struct TPPReaderSettingsView: View {
    
  @ObservedObject var settings: TPPReaderSettings
  
  var body: some View {
    VStack(spacing: 0) {
      fontButtons
      Divider()
      appearanceButtons
      Divider()
      fontSizeButtons
      Divider()
      brightnessControl
      Spacer()
    }
    .frame(maxWidth: .infinity)
    .background(
      Rectangle()
        .edgesIgnoringSafeArea([.top]) // This extends background to cover popover triangle
        .foregroundColor(Color(settings.backgroundColor))
    )
  }
  
  /// Set of font family buttons
  @ViewBuilder
  var fontButtons: some View {
    HStack(spacing: 0) {
      ForEach(TPPReaderFont.allCases.dropFirst()) { readerFont in
        Button {
          settings.changeFontFamily(fontFamilyIndex: readerFont.propertyIndex)
        } label: {
          Text("Aa").underline(readerFont.propertyIndex == settings.fontFamilyIndex)
        }
        .accessibility(label: Text(readerFont.accessibilityText))
        .buttonStyle(SettingsButtonStyle(settings: settings))
        .font(readerFont.font)

        if (readerFont.propertyIndex != TPPReaderFont.allCases.last?.propertyIndex) {
          Divider()
            .frame(height: buttonHeight)
        }
      }
    }
  }
  
  /// Set of reader appearance buttons
  @ViewBuilder
  var appearanceButtons: some View {
    HStack(spacing: 0) {
      ForEach(TPPReaderAppearance.allCases) { readerAppearance in
        Button {
          settings.changeAppearance(appearanceIndex: readerAppearance.propertyIndex)
        } label: {
          Text("ABCabc").underline(readerAppearance.propertyIndex == settings.appearanceIndex)
        }
        .accessibility(label: Text(readerAppearance.accessibilityText))
        .buttonStyle(SettingsButtonStyle(settings: settings, textColor: readerAppearance.associatedColors.textColor))
        .font(.system(size: 18))
        .background(
          Rectangle()
            .foregroundColor(Color(readerAppearance.associatedColors.backgroundColor))
        )

        if (readerAppearance.propertyIndex != TPPReaderAppearance.allCases.last?.propertyIndex) {
          Divider()
            .frame(height: buttonHeight)
        }
      }
    }
  }
  
  /// Buttons to decrease and increase the size of text font
  var fontSizeButtons: some View {
    HStack(alignment: .center, spacing: 0) {
      Button {
        settings.decreaseFontSize()
      } label: {
        fontSizeText(size: 14)
          .foregroundColor(Color(settings.textColor))
          .imageScale(.large)
          .opacity(imageOpacity(state: settings.canDecreaseFontSize))
      }
      .buttonStyle(SettingsButtonStyle(settings: settings))
      .disabled(!settings.canDecreaseFontSize)
      .accessibility(label: Text("DecreaseFontSize"))

      Divider()
        .frame(height: buttonHeight)

      Button {
        settings.increaseFontSize()
      } label: {
        fontSizeText(size: 20)
          .foregroundColor(Color(settings.textColor))
          .imageScale(.large)
          .opacity(imageOpacity(state: settings.canIncreaseFontSize))
      }
      .buttonStyle(SettingsButtonStyle(settings: settings))
      .disabled(!settings.canIncreaseFontSize)
      .accessibility(label: Text("IncreaseFontSize"))
    }
  }
  
  /// "A" text element for font size buttons
  ///
  /// Font size is number rather than style to avoid scaling.
  ///
  /// - Parameter size: text size
  /// - Returns: Text element
  @ViewBuilder
  func fontSizeText(size: Double) -> some View {
    Text("A")
      .font(.system(size: size, weight: .medium, design: .rounded))
  }
  
  /// Screen brightness control
  var brightnessControl: some View {
    HStack(spacing: 0) {
      Image(systemName: "sun.min")
        .foregroundColor(Color(settings.textColor))
      
      Slider(
        value: $settings.screenBrightness,
        in: 0...1.0,
        step: 0.01
      )
        .accentColor(Color(settings.textColor))
        .accessibility(label: Text("BrightnessSlider"))

      Image(systemName: "sun.max")
        .imageScale(.large)
        .foregroundColor(Color(settings.textColor))
    }
    .padding()
    .onReceive(NotificationCenter.default.publisher(for: UIScreen.brightnessDidChangeNotification)) { notification in
      if let screen = notification.object as? UIScreen, screen.brightness != settings.screenBrightness {
        settings.screenBrightness = screen.brightness
      }
    }
  }
  
  /// Opacity for images depending on the model variable state
  /// - Parameter state: Boolean variable, enabled or disabled
  /// - Returns: opacity for the state
  func imageOpacity(state: Bool) -> Double {
    state ? 1 : 0.3
  }
}

struct SettingsButtonStyle: ButtonStyle {
  
  @ObservedObject var settings: TPPReaderSettings
  
  var textColor: UIColor?
  
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundColor(Color(textColor ?? settings.textColor))
      .frame(minWidth: buttonHeight, maxWidth: .infinity, minHeight: buttonHeight)
      .contentShape(Rectangle())
  }
}

struct TPPReaderSettingsView_Previews: PreviewProvider {
  static var previews: some View {
    TPPReaderSettingsView(settings: TPPReaderSettings())
  }
}
