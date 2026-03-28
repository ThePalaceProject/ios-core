import UIKit

extension UILabel {

  /// Font name for the label. Usable as a `UI_APPEARANCE_SELECTOR`.
  @objc var fontName: String? {
    get {
      font.fontName
    }
    set {
      guard let newValue = newValue,
            let newFont = UIFont(name: newValue, size: font.pointSize) else { return }
      font = newFont
    }
  }
}
