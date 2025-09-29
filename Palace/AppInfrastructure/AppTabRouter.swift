import SwiftUI

// MARK: - AppTab

enum AppTab: Hashable {
  case catalog
  case myBooks
  case holds
  case settings
}

// MARK: - AppTabRouter

@MainActor
final class AppTabRouter: ObservableObject {
  @Published var selected: AppTab = .catalog
}

// MARK: - AppTabRouterHub

final class AppTabRouterHub {
  static let shared = AppTabRouterHub()
  private init() {}
  weak var router: AppTabRouter?
}
