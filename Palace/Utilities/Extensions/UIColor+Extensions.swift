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
  
  // Color component accessors for comparison
  var redComponent: CGFloat {
    var red: CGFloat = 0
    getRed(&red, green: nil, blue: nil, alpha: nil)
    return red
  }
  
  var greenComponent: CGFloat {
    var green: CGFloat = 0
    getRed(nil, green: &green, blue: nil, alpha: nil)
    return green
  }
  
  var blueComponent: CGFloat {
    var blue: CGFloat = 0
    getRed(nil, green: nil, blue: &blue, alpha: nil)
    return blue
  }
}
