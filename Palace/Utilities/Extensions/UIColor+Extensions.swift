import UIKit

extension UIColor {
  @objc class public func defaultLabelColor() -> UIColor {
    if #available(iOS 13, *) {
      return UIColor.label;
    } else {
      return UIColor.black;
    }
  }
}

extension UIColor {
  var hexString: String {
    let components = cgColor.components
    let r = Float(components?[0] ?? 0) * 255
    let g = Float(components?[1] ?? 0) * 255
    let b = Float(components?[2] ?? 0) * 255
    return String(format: "#%02lX%02lX%02lX", lroundf(r), lroundf(g), lroundf(b))
  }

  convenience init(hexString: String) {
    let scanner = Scanner(string: hexString)
    scanner.scanLocation = 1
    var hex: UInt64 = 0
    scanner.scanHexInt64(&hex)
    let r = CGFloat((hex & 0xFF0000) >> 16) / 255
    let g = CGFloat((hex & 0x00FF00) >> 8) / 255
    let b = CGFloat(hex & 0x0000FF) / 255
    self.init(red: r, green: g, blue: b, alpha: 1)
  }
  
  var isLight: Bool {
    guard let components = cgColor.components, components.count >= 3 else { return true }
    let brightness = ((components[0] * 299) + (components[1] * 587) + (components[2] * 114)) / 1000
    return brightness > 0.5
  }
}
