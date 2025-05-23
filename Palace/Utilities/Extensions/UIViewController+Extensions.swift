import SwiftUI

extension UIViewController {
  var topMostViewController: UIViewController {
    if let presented = presentedViewController {
      return presented.topMostViewController
    }
    if let nav = self as? UINavigationController,
       let visible = nav.visibleViewController {
      return visible.topMostViewController
    }
    if let tab = self as? UITabBarController,
       let selected = tab.selectedViewController {
      return selected.topMostViewController
    }
    return self
  }
}
