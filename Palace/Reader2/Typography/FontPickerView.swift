//
//  FontPickerView.swift
//  Palace
//
//  Typography system — font selection with grouped categories and previews.
//

import SwiftUI

/// Font picker grouped by category (Serif, Sans-Serif, Accessibility).
/// Each row shows the font name rendered in that font, plus sample text.
struct FontPickerView: View {

    let availableFonts: [TPPFontFamily]
    @Binding var selectedFont: TPPFontFamily
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                ForEach(FontCategory.allCases, id: \.self) { category in
                    let fonts = availableFonts.filter { $0.category == category }
                    if !fonts.isEmpty {
                        Section(header: Text(category.rawValue).accessibilityAddTraits(.isHeader)) {
                            ForEach(fonts) { font in
                                FontRow(
                                    font: font,
                                    isSelected: font == selectedFont,
                                    action: {
                                        selectedFont = font
                                        dismiss()
                                    }
                                )
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Font")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// A single font row showing the font name in that font and sample text.
private struct FontRow: View {

    let font: TPPFontFamily
    let isSelected: Bool
    let action: () -> Void

    // accesslint:disable A11Y.SWIFTUI.DYNAMIC_TYPE - Intentional fixed size for font preview
    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(font.displayName)
                        .font(Font(font.uiFont(size: 17)))
                        .foregroundColor(.primary)

                    Text(font.previewText)
                        .font(Font(font.uiFont(size: 13)))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                        .fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(font.displayName)
        .accessibilityHint("\(font.category.rawValue) font")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#if DEBUG
struct FontPickerView_Previews: PreviewProvider {
    static var previews: some View {
        FontPickerView(
            availableFonts: TPPFontFamily.allCases,
            selectedFont: .constant(.georgia)
        )
    }
}
#endif
