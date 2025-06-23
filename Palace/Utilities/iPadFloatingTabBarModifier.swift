import SwiftUI
import UIKit

// MARK: – Helper to find your root UITabBarController

/// Recursively searches a view-controller hierarchy for a UITabBarController
private func findTabBarController(_ vc: UIViewController) -> UITabBarController? {
  if let tbc = vc as? UITabBarController { return tbc }
  if let nav = vc as? UINavigationController {
    return nav.viewControllers.first.flatMap(findTabBarController)
  }
  if let presented = vc.presentedViewController {
    return findTabBarController(presented)
  }
  return nil
}

private func rootTabBarController() -> UITabBarController? {
  UIApplication.shared.connectedScenes
    .compactMap { $0 as? UIWindowScene }
    .flatMap { $0.windows }
    .first { $0.isKeyWindow }?
    .rootViewController
    .flatMap(findTabBarController)
}

// MARK: – Hide Modifier

private struct HideFloatingTabBarModifier: ViewModifier {
  let animated: Bool

  func body(content: Content) -> some View {
    content.onAppear {
      guard #available(iOS 18.0, *),
            UIDevice.current.userInterfaceIdiom == .pad,
            let tbc = rootTabBarController()
      else { return }
      tbc.setTabBarHidden(true, animated: animated)
    }
  }
}

public extension View {
  func hideFloatingTabBar(animated: Bool = false) -> some View {
    modifier(HideFloatingTabBarModifier(animated: animated))
  }
}

// MARK: – Show Modifier

private struct ShowFloatingTabBarModifier: ViewModifier {
  let animated: Bool

  func body(content: Content) -> some View {
    content.onAppear {
      guard #available(iOS 18.0, *),
            UIDevice.current.userInterfaceIdiom == .pad,
            let tbc = rootTabBarController()
      else { return }
      tbc.setTabBarHidden(false, animated: animated)
    }
  }
}

public extension View {
  func showFloatingTabBar(animated: Bool = true) -> some View {
    modifier(ShowFloatingTabBarModifier(animated: animated))
  }
}
