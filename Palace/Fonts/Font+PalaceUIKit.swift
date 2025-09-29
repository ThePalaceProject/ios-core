//
//  Font+Extensions.swift
//  Palace
//
//  Created by Vladimir Fedorov on 14.11.2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import SwiftUI

// MARK: - PalaceFontModifier

public struct PalaceFontModifier: ViewModifier {
  var style: Font.TextStyle
  var size: CGFloat?
  var weight: Font.Weight?

  public func body(content: Content) -> some View {
    content.font(
      .custom(palaceFontName, size: size ?? fontSize(for: style), relativeTo: style)
        .weight(weight ?? fontWeight(for: style))
    )
  }

  private let palaceFontName = "OpenSans-Regular"

  // Font sizes are described in pixels: https://www.figma.com/file/BxLs5QNmU5tCIKhO9ccAyh/TPP-UI---Style-Guidelines?type=design&node-id=1-12&mode=design&t=sGPJYuRIuFdWCIg3-0
  private func fontSize(for textStyle: Font.TextStyle) -> CGFloat {
    switch textStyle {
    case .largeTitle: 34
    case .title: 28
    case .title2: 22
    case .title3: 20
    case .headline: 17
    case .subheadline: 15
    case .body: 17
    default: UIFont.preferredFont(forTextStyle: translateTextStyle(textStyle)).pointSize
    }
  }

  private func fontWeight(for textStyle: Font.TextStyle) -> Font.Weight {
    switch textStyle {
    case .largeTitle: .bold
    case .title: .bold
    case .title2: .bold
    case .title3: .bold
    case .headline: .bold
    case .subheadline: .bold
    case .body: .regular
    default: .regular
    }
  }

  private func translateTextStyle(_ textStyle: Font.TextStyle) -> UIFont.TextStyle {
    switch textStyle {
    case .largeTitle: return .largeTitle
    case .title: return .title1
    case .title2: return .title2
    case .title3: return .title3
    case .headline: return .headline
    case .subheadline: return .subheadline
    case .body: return .body
    case .callout: return .callout
    case .footnote: return .footnote
    case .caption: return .caption1
    case .caption2: return .caption2
    @unknown default: return .body
    }
  }
}

public extension View {
  func palaceFont(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> some View {
    modifier(PalaceFontModifier(style: style, weight: weight))
  }

  func palaceFont(size: CGFloat, weight: Font.Weight? = nil) -> some View {
    modifier(PalaceFontModifier(style: .body, size: size, weight: weight))
  }
}
