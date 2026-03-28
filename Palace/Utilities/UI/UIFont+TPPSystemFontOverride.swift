import UIKit

// COEXISTENCE: ObjC originals provide these. Uncomment when ObjC files are removed.
//extension UIFont {
//
//  @objc class func customFont(forTextStyle style: UIFont.TextStyle) -> UIFont {
//    customFont(forTextStyle: style, multiplier: 1.0)
//  }
//
//  @objc class func customFont(forTextStyle style: UIFont.TextStyle, multiplier: CGFloat) -> UIFont {
//    let preferredFont = UIFont.preferredFont(forTextStyle: style)
//    let traits = preferredFont.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
//    let weight = traits?[.weight] as? NSNumber ?? NSNumber(value: 0)
//
//    let attributes: [UIFontDescriptor.AttributeName: Any] = [
//      .traits: [UIFontDescriptor.TraitKey.weight: weight]
//    ]
//
//    let newDescriptor = UIFontDescriptor(name: preferredFont.fontName, size: preferredFont.pointSize)
//      .withFamily(TPPConfiguration.systemFontFamilyName())
//      .addingAttributes(attributes)
//
//    return UIFont(descriptor: newDescriptor, size: preferredFont.pointSize * multiplier)
//  }
//
//  @objc class func customBoldFont(forTextStyle style: UIFont.TextStyle) -> UIFont {
//    let preferredFont = UIFont.preferredFont(forTextStyle: style)
//    let attributes: [UIFontDescriptor.AttributeName: Any] = [
//      .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.bold.rawValue]
//    ]
//
//    let newDescriptor = UIFontDescriptor(name: preferredFont.fontName, size: preferredFont.pointSize)
//      .withFamily(TPPConfiguration.systemFontFamilyName())
//      .addingAttributes(attributes)
//
//    return UIFont(descriptor: newDescriptor, size: preferredFont.pointSize)
//  }
//}
