//
//  ButtonView.swift
//  Palace
//
//  Created by Maurice Carrier on 2/8/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import SwiftUI

struct ButtonView: View {
  
  var title: String
  var indicatorDate: Date? = nil
  var backgroundFill: Color? = nil
  var action: () -> Void
  
  private var accessiblityString: String {
    guard let untilDate = indicatorDate?.timeUntilString(suffixType: .long) else {
      return title
    }

    return "\(title).\(untilDate) remaining"
  }
    
  var body: some View {
    Button (action: action) {
      HStack(alignment: .center, spacing: 5) {
        indicatorView
        Text(title)
      }
      .padding()
    }
    .fixedSize()
    .buttonStyle(AnimatedButton(backgroundColor: backgroundFill))
    .accessibilityLabel(accessiblityString)
  }
  
  @ViewBuilder private var indicatorView: some View {
    if let endDate = indicatorDate?.timeUntilString(suffixType: .short) {
      VStack(spacing: 2) {
        ImageProviders.MyBooksView.clock
          .resizable()
          .square(length: 14)
        Text(endDate)
          .font(.system(size: 10))
      }
      .padding(.leading, -7)
      .foregroundColor(Color(TPPConfiguration.mainColor()))
    }
  }
}

struct AnimatedButton: ButtonStyle {
  var backgroundColor: Color? = nil

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .frame(height: 35)
      .buttonStyle(.plain)
      .background(backgroundColor)
      .overlay(
        RoundedRectangle(cornerRadius: 3)
          .stroke(backgroundColor ?? Color(TPPConfiguration.mainColor()), lineWidth: 1)
      )
      .opacity(configuration.isPressed ? 0.5 : 1.0)
  }
}
