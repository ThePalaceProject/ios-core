import UIKit

extension UIFont {
    @objc class func palaceFont(ofSize fontSize: CGFloat) -> UIFont {
        UIFont(name: TPPConfiguration.systemFontName(), size: fontSize) ?? .systemFont(ofSize: fontSize)
    }

    @objc class func semiBoldPalaceFont(ofSize fontSize: CGFloat) -> UIFont {
        UIFont(name: TPPConfiguration.semiBoldSystemFontName(), size: fontSize) ?? .systemFont(ofSize: fontSize, weight: .semibold)
    }

    @objc class func boldPalaceFont(ofSize fontSize: CGFloat) -> UIFont {
        UIFont(name: TPPConfiguration.boldSystemFontName(), size: fontSize) ?? .boldSystemFont(ofSize: fontSize)
    }
}
