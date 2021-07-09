import Foundation

@objc extension UIApplication {
  static var darkModeEnabled: Bool {
    if #available(iOS 13, *) {
      return UITraitCollection.current.userInterfaceStyle == .dark
    }
    
    return false
  }
}
