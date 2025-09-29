import UIKit

extension UIFont {
  @objc class func palaceFont(ofSize fontSize: CGFloat) -> UIFont {
    UIFont(name: TPPConfiguration.systemFontName(), size: fontSize)!
  }

  @objc class func semiBoldPalaceFont(ofSize fontSize: CGFloat) -> UIFont {
    UIFont(name: TPPConfiguration.semiBoldSystemFontName(), size: fontSize)!
  }

  @objc class func boldPalaceFont(ofSize fontSize: CGFloat) -> UIFont {
    UIFont(name: TPPConfiguration.boldSystemFontName(), size: fontSize)!
  }
}
