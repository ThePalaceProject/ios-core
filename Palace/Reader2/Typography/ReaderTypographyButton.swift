//
//  ReaderTypographyButton.swift
//  Palace
//
//  Typography system — UIKit-compatible button to present the typography sheet.
//

import SwiftUI
import UIKit

/// A UIKit-compatible button (UIViewRepresentable) that presents the typography settings sheet.
/// Drop this into the reader toolbar to give users access to advanced typography controls.
///
/// Usage in UIKit:
/// ```swift
/// let button = ReaderTypographyButtonUIKit()
/// button.onTap = { [weak self] in
///     self?.presentTypographySheet()
/// }
/// let barButtonItem = UIBarButtonItem(customView: button)
/// ```
///
/// Usage in SwiftUI:
/// ```swift
/// ReaderTypographyButton(typographyService: service)
/// ```
struct ReaderTypographyButton: View {

    /// Whether the advanced typography feature is enabled.
    static var isEnabled: Bool {
        RemoteFeatureFlags.shared.isFeatureEnabled(.advancedTypographyEnabled)
    }

    let typographyService: TypographyServiceProtocol?
    @State private var showTypographySheet = false

    init(typographyService: TypographyServiceProtocol? = nil) {
        self.typographyService = typographyService
    }

    var body: some View {
        if !Self.isEnabled { EmptyView(); return }
        Button {
            showTypographySheet = true
        } label: {
            Image(systemName: "textformat.size")
                .font(.body)
                .foregroundColor(.accentColor)
        }
        .accessibilityLabel("Typography Settings")
        .accessibilityHint("Opens advanced typography controls")
        .sheet(isPresented: $showTypographySheet) {
            TypographySettingsView(
                viewModel: TypographySettingsViewModel(
                    typographyService: typographyService
                )
            )
        }
    }
}

/// UIKit button that triggers typography sheet presentation.
/// Designed to be used as a `UIBarButtonItem` custom view in the reader toolbar.
final class ReaderTypographyButtonUIKit: UIButton {

    /// Called when the button is tapped. The presenting VC should show the typography sheet.
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        let image = UIImage(systemName: "textformat.size", withConfiguration: config)
        setImage(image, for: .normal)
        tintColor = .systemBlue
        addTarget(self, action: #selector(didTap), for: .touchUpInside)

        accessibilityLabel = NSLocalizedString("Typography Settings", comment: "Typography button accessibility label")
        accessibilityHint = NSLocalizedString("Opens advanced typography controls", comment: "Typography button accessibility hint")
    }

    @objc private func didTap() {
        onTap?()
    }

    /// Creates a UIHostingController wrapping the typography settings view,
    /// ready to be presented as a sheet.
    /// - Parameter service: The typography service instance to use. Defaults to shared.
    /// - Returns: A UIHostingController configured for sheet presentation.
    static func makeTypographySheet(service: TypographyServiceProtocol? = nil) -> UIViewController {
        let viewModel = TypographySettingsViewModel(typographyService: service)
        let view = TypographySettingsView(viewModel: viewModel)
        let hostingController = UIHostingController(rootView: view)
        hostingController.modalPresentationStyle = .pageSheet

        if let sheet = hostingController.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 20
        }

        return hostingController
    }
}

#if DEBUG
struct ReaderTypographyButton_Previews: PreviewProvider {
    static var previews: some View {
        ReaderTypographyButton()
    }
}
#endif
