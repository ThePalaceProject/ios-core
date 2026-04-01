import UIKit

extension UIButton {

  @objc var titleFontName: String? {
    get {
      return titleLabel?.font.fontName
    }
    set {
      guard let newFontName = newValue,
            let fontSize = titleLabel?.font.pointSize,
            let newFont = UIFont(name: newFontName, size: fontSize) else { return }
      titleLabel?.font = newFont
    }
  }
}
