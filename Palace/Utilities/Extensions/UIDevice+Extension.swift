import UIKit

extension UIDevice {
  var isIpad: Bool {
    userInterfaceIdiom == .pad
  }

  var isIphone: Bool {
    userInterfaceIdiom == .phone
  }
}
