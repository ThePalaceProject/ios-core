//
//  ActionButtonView.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import SwiftUI

/// Reusable action button with adaptive colors and loading states.
/// Use `.primary` for the main CTA (filled) and `.secondary` for supporting actions (outlined).
struct ActionButtonView: View {
    typealias Constants = AccountDetailView.Layout

    enum Style {
        case primary
        case secondary
    }

    let title: String
    let isLoading: Bool
    var style: Style = .primary
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var isDarkBackground: Bool {
        colorScheme == .dark
    }

    private var fillColor: Color {
        isDarkBackground ? .white : .black
    }

    private var primaryTextColor: Color {
        isDarkBackground ? .black : .white
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .tint(style == .primary ? primaryTextColor : fillColor)
                }
                Text(title)
                    .palaceFont(.body, weight: .semibold)
                    .opacity(isLoading ? 0.5 : 1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Constants.buttonHeight)
            .background(style == .primary ? fillColor : Color.clear)
            .foregroundColor(style == .primary ? primaryTextColor : fillColor)
            .cornerRadius(Constants.buttonCornerRadius)
            .overlay(
                style == .secondary
                    ? RoundedRectangle(cornerRadius: Constants.buttonCornerRadius).stroke(fillColor, lineWidth: 1.5)
                    : nil
            )
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
