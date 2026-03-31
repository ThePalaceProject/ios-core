//
//  PresetCard.swift
//  Palace
//
//  Typography system — reusable card showing a typography preset with mini preview.
//

import SwiftUI

/// A compact card that previews a typography preset.
/// Shows the preset name and a miniature text sample rendered with the preset's settings.
struct PresetCard: View {

    let preset: TypographyPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                // Mini text preview
                Text("Aa")
                    .font(Font(preset.settings.fontFamily.uiFont(size: 22)))
                    .foregroundColor(Color(preset.settings.theme.textColor))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)

                // Preset name
                Text(preset.name)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(Color(preset.settings.theme.textColor))
                    .frame(maxWidth: .infinity, alignment: .center)

                // Description
                Text(preset.description)
                    .font(.caption2)
                    .foregroundColor(Color(preset.settings.theme.textColor).opacity(0.7))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 8)
            }
            .frame(width: 120, height: 100)
            .background(Color(preset.settings.theme.backgroundColor))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3),
                            lineWidth: isSelected ? 2.5 : 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.name) preset")
        .accessibilityHint(preset.description)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#if DEBUG
struct PresetCard_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 12) {
            PresetCard(preset: .classic, isSelected: true, action: {})
            PresetCard(preset: .modern, isSelected: false, action: {})
            PresetCard(preset: .nightReader, isSelected: false, action: {})
        }
        .padding()
    }
}
#endif
