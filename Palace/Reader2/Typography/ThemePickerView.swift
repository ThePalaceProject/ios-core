//
//  ThemePickerView.swift
//  Palace
//
//  Typography system — visual theme selection with circular color swatches.
//

import SwiftUI

/// Displays circular color swatches for each reader theme.
/// The selected theme shows a ring highlight.
struct ThemePickerView: View {

    @Binding var selectedTheme: ReaderTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Theme")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 16) {
                ForEach(ReaderTheme.allCases) { theme in
                    ThemeSwatch(
                        theme: theme,
                        isSelected: theme == selectedTheme,
                        action: { selectedTheme = theme }
                    )
                }
                Spacer()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// A single circular swatch representing a reader theme.
private struct ThemeSwatch: View {

    let theme: ReaderTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // Outer selection ring
                Circle()
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5)
                    .frame(width: 44, height: 44)

                // Swatch fill
                Circle()
                    .fill(theme.swatchColor)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Circle()
                            .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
                    )

                // "A" letter preview showing text color
                Text("A")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.textSwiftUI)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.displayName) theme")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Double tap to select the \(theme.displayName) theme")
    }
}

#if DEBUG
struct ThemePickerView_Previews: PreviewProvider {
    static var previews: some View {
        ThemePickerView(selectedTheme: .constant(.sepia))
            .previewLayout(.sizeThatFits)
    }
}
#endif
