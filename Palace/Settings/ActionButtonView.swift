//
//  ActionButtonView.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import SwiftUI

/// Reusable action button with adaptive colors and loading states
struct ActionButtonView: View {
  typealias Constants = AccountDetailView.Layout
  
  let title: String
  let isLoading: Bool
  let action: () -> Void
  
  @Environment(\.colorScheme) private var colorScheme
  
  private var isDarkBackground: Bool {
    colorScheme == .dark
  }
  
  private var buttonBackgroundColor: Color {
    isDarkBackground ? .white : .black
  }
  
  private var buttonTextColor: Color {
    isDarkBackground ? .black : .white
  }
  
  var body: some View {
    Button(action: action) {
      ZStack {
        if isLoading {
          ProgressView()
            .progressViewStyle(CircularProgressViewStyle())
            .tint(buttonTextColor)
        }
        Text(title)
          .font(.system(size: AccountDetailView.Typography.buttonSize, weight: .semibold))
          .opacity(isLoading ? 0.5 : 1)
      }
      .frame(maxWidth: .infinity)
      .frame(height: Constants.buttonHeight)
      .background(buttonBackgroundColor)
      .foregroundColor(buttonTextColor)
      .cornerRadius(Constants.buttonCornerRadius)
    }
    .disabled(isLoading)
    .buttonStyle(.plain)
  }
}

/// Separator line for sections
struct SectionSeparator: View {
  var body: some View {
    Rectangle()
      .fill(Color(UIColor.separator))
      .frame(height: AccountDetailView.Layout.separatorHeight)
  }
}

