//
//  TypographySettingsView.swift
//  Palace
//
//  Typography system — main settings panel with live preview.
//

import SwiftUI

/// Main typography settings panel, presented as a bottom sheet from the reader.
/// Contains preset selection, font picker, sliders for fine-tuning, and a live preview.
struct TypographySettingsView: View {

    @ObservedObject var viewModel: TypographySettingsViewModel
    @State private var showFontPicker = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 0) {
                    // Live preview area
                    previewSection

                    Divider()
                        .padding(.horizontal)

                    // Preset selector
                    presetSection

                    Divider()
                        .padding(.horizontal)

                    // Theme picker
                    ThemePickerView(selectedTheme: $viewModel.theme)

                    Divider()
                        .padding(.horizontal)

                    // Font family
                    fontFamilySection

                    Divider()
                        .padding(.horizontal)

                    // Font size
                    sliderSection(
                        title: "Font Size",
                        value: $viewModel.fontSize,
                        range: TypographySettings.minFontSize...TypographySettings.maxFontSize,
                        step: TypographySettings.fontSizeStep,
                        format: "%.0f pt",
                        accessibilityLabel: "Font size"
                    )

                    Divider()
                        .padding(.horizontal)

                    // Line spacing
                    sliderSection(
                        title: "Line Spacing",
                        value: $viewModel.lineSpacing,
                        range: TypographySettings.minLineSpacing...TypographySettings.maxLineSpacing,
                        step: TypographySettings.lineSpacingStep,
                        format: "%.1fx",
                        accessibilityLabel: "Line spacing"
                    )

                    Divider()
                        .padding(.horizontal)

                    // Margin width
                    marginSection

                    Divider()
                        .padding(.horizontal)

                    // Paragraph spacing
                    sliderSection(
                        title: "Paragraph Spacing",
                        value: $viewModel.paragraphSpacing,
                        range: TypographySettings.minParagraphSpacing...TypographySettings.maxParagraphSpacing,
                        step: 2,
                        format: "%.0f pt",
                        accessibilityLabel: "Paragraph spacing"
                    )

                    Divider()
                        .padding(.horizontal)

                    // Text alignment
                    alignmentSection

                    Divider()
                        .padding(.horizontal)

                    // Letter spacing
                    sliderSection(
                        title: "Letter Spacing",
                        value: $viewModel.letterSpacing,
                        range: TypographySettings.minLetterSpacing...TypographySettings.maxLetterSpacing,
                        step: 0.1,
                        format: "%.1f pt",
                        accessibilityLabel: "Letter spacing"
                    )

                    Divider()
                        .padding(.horizontal)

                    // Word spacing
                    sliderSection(
                        title: "Word Spacing",
                        value: $viewModel.wordSpacing,
                        range: TypographySettings.minWordSpacing...TypographySettings.maxWordSpacing,
                        step: 0.5,
                        format: "%.1f pt",
                        accessibilityLabel: "Word spacing"
                    )

                    // Reset button
                    if viewModel.hasCustomOverrides {
                        Divider()
                            .padding(.horizontal)
                        resetSection
                    }

                    Spacer(minLength: 32)
                }
            }
            .background(Color(viewModel.currentSettings.theme.backgroundColor))
            .navigationTitle("Typography")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showFontPicker) {
            FontPickerView(
                availableFonts: viewModel.availableFonts,
                selectedFont: $viewModel.fontFamily
            )
        }
    }

    // MARK: - Preview Section

    private var previewSection: some View {
        VStack(spacing: 0) {
            Text(viewModel.previewText)
                .font(Font(viewModel.currentSettings.fontFamily.uiFont(size: viewModel.currentSettings.fontSize)))
                .foregroundColor(Color(viewModel.currentSettings.theme.textColor))
                .lineSpacing((viewModel.currentSettings.lineSpacing - 1.0) * viewModel.currentSettings.fontSize)
                .tracking(viewModel.currentSettings.letterSpacing)
                .multilineTextAlignment(viewModel.currentSettings.textAlignment == .justified ? .leading : .leading)
                .padding(.horizontal, viewModel.currentSettings.marginLevel.cssPercentage * 2)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(viewModel.currentSettings.theme.backgroundColor))
                .accessibilityLabel("Typography preview")
                .accessibilityHint("Shows how text will appear with current settings")
        }
    }

    // MARK: - Preset Section

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Presets")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .padding(.horizontal)
                .accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(TypographyPreset.allPresets) { preset in
                        PresetCard(
                            preset: preset,
                            isSelected: viewModel.selectedPreset?.id == preset.id,
                            action: { viewModel.selectPreset(preset) }
                        )
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Font Family Section

    private var fontFamilySection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Font")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)

                Text(viewModel.fontFamily.displayName)
                    .font(Font(viewModel.fontFamily.uiFont(size: 17)))
                    .foregroundColor(.primary)
            }

            Spacer()

            Button {
                showFontPicker = true
            } label: {
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.body)
            }
            .accessibilityLabel("Choose font")
            .accessibilityValue(viewModel.fontFamily.displayName)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { showFontPicker = true }
    }

    // MARK: - Margin Section

    private var marginSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Margins")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .accessibilityAddTraits(.isHeader)

            Picker("Margin Width", selection: $viewModel.marginLevel) {
                ForEach(MarginLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Margin width")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Alignment Section

    private var alignmentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Alignment")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 16) {
                ForEach(TextAlignmentOption.allCases) { alignment in
                    Button {
                        viewModel.updateTextAlignment(alignment)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: alignment.systemImage)
                                .font(.title2)
                            Text(alignment.displayName)
                                .font(.caption)
                        }
                        .foregroundColor(viewModel.textAlignment == alignment ? .accentColor : .secondary)
                        .frame(width: 80, height: 56)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(viewModel.textAlignment == alignment
                                      ? Color.accentColor.opacity(0.1)
                                      : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(viewModel.textAlignment == alignment
                                        ? Color.accentColor
                                        : Color.gray.opacity(0.3),
                                        lineWidth: viewModel.textAlignment == alignment ? 1.5 : 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(alignment.displayName) alignment")
                    .accessibilityAddTraits(viewModel.textAlignment == alignment ? .isSelected : [])
                }
                Spacer()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Reset Section

    private var resetSection: some View {
        Button {
            viewModel.resetToPreset()
        } label: {
            HStack {
                Image(systemName: "arrow.counterclockwise")
                Text("Reset to Preset")
            }
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundColor(.accentColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .accessibilityLabel("Reset to preset defaults")
    }

    // MARK: - Reusable Slider

    private func sliderSection(
        title: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        step: CGFloat,
        format: String,
        accessibilityLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)

                Spacer()

                Text(String(format: format, value.wrappedValue))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }

            Slider(
                value: value,
                in: range,
                step: step
            )
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(String(format: format, value.wrappedValue))
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

#if DEBUG
struct TypographySettingsView_Previews: PreviewProvider {
    static var previews: some View {
        TypographySettingsView(viewModel: TypographySettingsViewModel())
    }
}
#endif
