import UIKit

extension UILabel {

  @objc var fontName: String? {
    get {
      return font.fontName
    }
    set {
      guard let newFontName = newValue else { return }
      let fontSize = font.pointSize
      if let newFont = UIFont(name: newFontName, size: fontSize) {
        font = newFont
      }
    }
  }
}
