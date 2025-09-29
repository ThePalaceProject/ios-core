import UIKit

public extension UIColor {
  @objc class func defaultLabelColor() -> UIColor {
    if #available(iOS 13, *) {
      UIColor.label
    } else {
      UIColor.black
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
}
