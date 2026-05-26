import Foundation
import SwiftUI
import UIKit

struct LibraryNavTitleView: View {
    var onTap: (() -> Void)?
    private let accountsManager: AccountsManager

    /// Key for caching the last-known library name so it shows instantly
    /// on launch instead of flashing "Catalog" while the account loads.
    static let cachedNameKey = "LibraryNavTitle.cachedName"

    init(onTap: (() -> Void)? = nil, accountsManager: AccountsManager = AppContainer.production().accountsManager) {
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

    /// The display name: live account name → cached name → "Catalog" fallback.
    private var displayName: String {
        if let name = accountsManager.currentAccount?.name {
            // Cache for next launch
            UserDefaults.standard.set(name, forKey: Self.cachedNameKey)
            return name
        }
        return UserDefaults.standard.string(forKey: Self.cachedNameKey)
            ?? NSLocalizedString("Catalog", comment: "")
    }

    private var content: some View {
        HStack(spacing: 10) {
            if let logo = accountsManager.currentAccount?.logo {
                Image(uiImage: logo)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
            }
            Text(displayName)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

