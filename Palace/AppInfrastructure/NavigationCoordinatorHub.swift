import Foundation

final class NavigationCoordinatorHub {
  static let shared = NavigationCoordinatorHub()
  private init() {}
  weak var coordinator: NavigationCoordinator?
}


