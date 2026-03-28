//
//  CarModeEntryButton.swift
//  Palace
//
//  A button to enter car mode from the regular audiobook player toolbar.
//  Uses SF Symbol car.fill icon. Ready to integrate into existing player UI.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI

// MARK: - CarModeEntryButton

public struct CarModeEntryButton: View {

    /// Whether the Car Mode feature is enabled.
    static var isEnabled: Bool {
        RemoteFeatureFlags.shared.isFeatureEnabled(.carModeEnabled)
    }

    let action: () -> Void

    /// Size of the button icon.
    var iconSize: CGFloat = 22

    /// Whether to show the "Car Mode" label below the icon.
    var showsLabel: Bool = false

    public var body: some View {
        if !Self.isEnabled { EmptyView(); return }
        Button(action: action) {
            if showsLabel {
                VStack(spacing: 4) {
                    carIcon
                    Text("Car Mode")
                        .font(.system(size: 12, weight: .medium))
                }
            } else {
                carIcon
            }
        }
        .accessibilityLabel("Car Mode")
        .accessibilityHint("Opens simplified driving interface for audiobook playback")
    }

    private var carIcon: some View {
        Image(systemName: "car.fill")
            .font(.system(size: iconSize, weight: .medium))
            .foregroundColor(.primary)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

// MARK: - UIKit Wrapper

/// UIKit-compatible wrapper for placing CarModeEntryButton in UIBarButtonItem or UIKit toolbars.
public final class CarModeEntryButtonUIKit {

    /// Creates a UIBarButtonItem that triggers car mode entry.
    /// - Parameter action: Closure called when the button is tapped.
    /// - Returns: A configured UIBarButtonItem.
    public static func barButtonItem(action: @escaping () -> Void) -> UIBarButtonItem {
        let button = UIBarButtonItem(
            image: UIImage(systemName: "car.fill"),
            style: .plain,
            target: nil,
            action: nil
        )
        button.accessibilityLabel = "Car Mode"
        button.accessibilityHint = "Opens simplified driving interface for audiobook playback"

        // Use UIAction for the target-action pattern
        button.primaryAction = UIAction { _ in action() }

        return button
    }
}

// MARK: - Preview

#if DEBUG
struct CarModeEntryButton_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 20) {
            CarModeEntryButton(action: {})
            CarModeEntryButton(action: {}, showsLabel: true)
        }
        .padding()
    }
}
#endif
