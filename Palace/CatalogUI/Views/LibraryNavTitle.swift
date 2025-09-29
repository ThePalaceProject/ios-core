import Foundation
import SwiftUI
import UIKit

// MARK: - LibraryNavTitleView

struct LibraryNavTitleView: View {
  var onTap: (() -> Void)?

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
      if let logo = AccountsManager.shared.currentAccount?.logo {
        Image(uiImage: logo)
          .resizable()
          .scaledToFit()
          .frame(width: 28, height: 28)
          .clipShape(Circle())
      }
      Text(AccountsManager.shared.currentAccount?.name ?? NSLocalizedString("Catalog", comment: ""))
        .font(.headline)
        .lineLimit(2)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

// MARK: - LibraryNavTitleFactory

@objc final class LibraryNavTitleFactory: NSObject {
  @objc static func makeTitleView() -> UIView {
    let container = UIStackView()
    container.axis = .horizontal
    container.alignment = .center
    container.spacing = 8

    if let logo = AccountsManager.shared.currentAccount?.logo {
      let imageView = UIImageView(image: logo)
      imageView.contentMode = .scaleAspectFit
      imageView.clipsToBounds = true
      imageView.layer.cornerRadius = 12
      imageView.translatesAutoresizingMaskIntoConstraints = false
      imageView.widthAnchor.constraint(equalToConstant: 24).isActive = true
      imageView.heightAnchor.constraint(equalToConstant: 24).isActive = true
      container.addArrangedSubview(imageView)
    }

    let titleLabel = UILabel()
    titleLabel.text = AccountsManager.shared.currentAccount?.name ?? NSLocalizedString("Catalog", comment: "")
    titleLabel.font = UIFont.preferredFont(forTextStyle: .headline)
    titleLabel.adjustsFontForContentSizeCategory = true
    container.addArrangedSubview(titleLabel)

    return container
  }
}
