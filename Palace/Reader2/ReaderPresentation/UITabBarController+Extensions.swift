
import UIKit

extension UITabBarController {
  /// Recursively searches a view‐controller hierarchy for a UITabBarController.
  static private func findTabBarController(in vc: UIViewController) -> UITabBarController? {
    if let tbc = vc as? UITabBarController { return tbc }
    if let nav = vc as? UINavigationController {
      return nav.viewControllers.first.flatMap(findTabBarController)
    }
    if let presented = vc.presentedViewController {
      return findTabBarController(in: presented)
    }
    return nil
  }
  
  /// Locates the root UITabBarController from the key window (handles multi‐scene apps).
  static private func rootTabBarController() -> UITabBarController? {
    for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
      if let keyWin = scene.windows.first(where: { $0.isKeyWindow }),
         let root = keyWin.rootViewController,
         let tbc  = findTabBarController(in: root) {
        return tbc
      }
    }
    // Fallback for single‐window apps:
    if let keyWin = UIApplication.shared.windows.first(where: { $0.isKeyWindow }),
       let root   = keyWin.rootViewController {
      return findTabBarController(in: root)
    }
    return nil
  }
  
  /// Hides the iPadOS 18 “floating” tab bar if running on iPad/iOS18+; no‐ops elsewhere.
  static public func hideFloatingTabBar(animated: Bool = false) {
    guard #available(iOS 18.0, *),
          UIDevice.current.userInterfaceIdiom == .pad,
          let tbc = rootTabBarController()
    else { return }
    
    tbc.setTabBarHidden(true, animated: animated)
  }
  
  /// Shows the iPadOS 18 “floating” tab bar if running on iPad/iOS18+; no‐ops elsewhere.
  static public func showFloatingTabBar(animated: Bool = true) {
    guard #available(iOS 18.0, *),
          UIDevice.current.userInterfaceIdiom == .pad,
          let tbc = rootTabBarController()
    else { return }
    
    tbc.setTabBarHidden(false, animated: animated)
  }
}
