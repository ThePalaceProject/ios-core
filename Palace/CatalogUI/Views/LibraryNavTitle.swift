import Foundation
import SwiftUI
import UIKit

struct LibraryNavTitleView: View {
    var onTap: (() -> Void)?
    private let accountsManager: AccountsManager

    init(onTap: (() -> Void)? = nil, accountsManager: AccountsManager = AccountsManager.shared) {
        self.onTap = onTap
        self.accountsManager = accountsManager
    }

    @ViewBuilder
    var body: some View {
        if let onTap {
            Button(action: onTap) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 10) {
            if let logo = accountsManager.currentAccount?.logo {
                Image(uiImage: logo)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
                    .accessibilityHidden(true) // Decorative, title label provides context
            }
            Text(accountsManager.currentAccount?.name ?? NSLocalizedString("Catalog", comment: ""))
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

@objc final class LibraryNavTitleFactory: NSObject {
    @objc static func makeTitleView(accountsManager: AccountsManager = AccountsManager.shared) -> UIView {
        let container = UIStackView()
        container.axis = .horizontal
        container.alignment = .center
        container.spacing = 8

        if let logo = accountsManager.currentAccount?.logo {
            let imageView = UIImageView(image: logo)
            imageView.contentMode = .scaleAspectFit
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 12
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.widthAnchor.constraint(equalToConstant: 24).isActive = true
            imageView.heightAnchor.constraint(equalToConstant: 24).isActive = true
            imageView.isAccessibilityElement = false // Decorative, title label provides context
            container.addArrangedSubview(imageView)
        }

        let titleLabel = UILabel()
        titleLabel.text = accountsManager.currentAccount?.name ?? NSLocalizedString("Catalog", comment: "")
        titleLabel.font = UIFont.preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        container.addArrangedSubview(titleLabel)

        return container
    }
}
