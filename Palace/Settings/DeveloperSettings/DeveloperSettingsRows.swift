//
//  DeveloperSettingsRows.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//
//  Shared SwiftUI row-builder views + a presenter resolver used by both the
//  Testing screen (`DeveloperSettingsView`) and the app-level Advanced screen
//  (`AppAdvancedSettingsView`). Keeping the row shapes here means the two
//  screens render identical cells without duplicating layout code.
//

import SwiftUI

// MARK: - Presenter resolution

/// Resolves the current top-most UIViewController for the alert / mail /
/// action-sheet flows the developer settings actions present. Mirrors the
/// `topViewController()` helper in `TPPSettingsView`.
@MainActor
enum DeveloperSettingsPresenter {
    static func topViewController() -> UIViewController? {
        guard let root = UIApplication.shared.mainKeyWindow?.rootViewController else {
            return nil
        }
        var current = root
        while let presented = current.presentedViewController {
            current = presented
        }
        return current
    }
}

// MARK: - Rows

/// A neutral label + green switch row. Matches the UIKit `.default`-style
/// switch cells (Enable Hidden Libraries, Triage Bot toggles, etc.).
struct DevToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .palaceFont(.body)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .tint(.green)
    }
}

/// A tinted-text action button row (blue = action, red = destructive, black =
/// neutral). Matches `cell.textLabel?.textColor = .systemBlue/.systemRed`.
struct DevActionRow: View {
    let title: String
    var color: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .palaceFont(.body)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

/// A disclosure row: leading label + trailing gray detail + chevron. Matches
/// the `.value1`-style cells (Anthropic API Key, Test Holds Configuration,
/// Simulate Borrow Error, …). Tapping fires `action`.
struct DevDisclosureValueRow: View {
    let title: String
    var titleColor: Color = .primary
    let value: String
    var valueColor: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .palaceFont(.body)
                    .foregroundStyle(titleColor)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(value)
                    .palaceFont(.body)
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
        }
        .buttonStyle(.plain)
    }
}

/// A `.subtitle`-style disclosure row: title on top, gray multi-line subtitle
/// below, chevron trailing. Matches the reset rows + notification rows.
struct DevSubtitleDisclosureRow: View {
    let title: String
    var titleColor: Color = .primary
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .palaceFont(.body)
                        .foregroundStyle(titleColor)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
        }
        .buttonStyle(.plain)
    }
}

/// A `.subtitle` row with NO chevron: title on top, gray multi-line subtitle
/// below. Matches the reset rows (`cellForResetThisLibrary`, `cellForFullReset`)
/// which set a red title + subtitle but no `accessoryType`.
struct DevSubtitleRow: View {
    let title: String
    var titleColor: Color = .primary
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .palaceFont(.body)
                    .foregroundStyle(titleColor)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

/// A non-tappable `.subtitle` row whose subtitle is a monospaced value (FCM
/// token). No chevron. Matches `cellForFCMToken`.
struct DevMonospaceValueRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .palaceFont(.body)
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }
}

/// The Library Registry Debugging row: `https://` prefix, an inline text field,
/// a `/libraries/qa` suffix, and Clear / Set bordered buttons underneath.
/// Reproduces `TPPRegistryDebuggingCell`.
struct DevRegistryDebuggingRow: View {
    @Binding var input: String
    let onClear: () -> Void
    let onSet: () -> Void

    /// A full URL is fetched verbatim, so the affix hints only make sense for a
    /// bare-host entry. Hide them once the input looks like a full URL — matches
    /// `TPPRegistryDebuggingCell.updateAffixVisibility`.
    private var isFullURL: Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("http")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                if !isFullURL {
                    Text("https://")
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                VStack(spacing: 0) {
                    TextField("host, or full https:// URL", text: $input)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .frame(minWidth: 120)
                    Rectangle()
                        .fill(Color.gray)
                        .frame(height: 1)
                }
                if !isFullURL {
                    Text("/libraries/qa")
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            }

            HStack(spacing: 30) {
                borderedButton("Clear", action: onClear)
                    .accessibilityHint(Text("Clears the registry data for this book"))
                borderedButton("Set", action: onSet)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 6)
    }

    private func borderedButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .palaceFont(.body)
                .foregroundStyle(Color(UIColor.defaultLabelColor()))
                .frame(width: 125, height: 34)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(UIColor.defaultLabelColor()), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
