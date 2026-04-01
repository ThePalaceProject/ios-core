import UIKit

@objc class TPPConfiguration: NSObject {

  @objc static func mainFeedURL() -> URL? {
    if let customURL = TPPSettings.shared.customMainFeedURL {
      return customURL
    }
    return TPPSettings.shared.accountMainFeedURL
  }

  @objc static func minimumVersionURL() -> URL? {
    return URL(string: "http://www.librarysimplified.org/simplye-client/minimum-version")
  }

  @objc static func accentColor() -> UIColor {
    return UIColor(red: 0.0/255.0, green: 144.0/255.0, blue: 196.0/255.0, alpha: 1.0)
  }

  @objc static func backgroundColor() -> UIColor {
    return UIColor(named: "ColorBackground") ?? UIColor(white: 250.0/255.0, alpha: 1.0)
  }

  @objc static func readerBackgroundColor() -> UIColor {
    return UIColor(white: 250.0/255.0, alpha: 1.0)
  }

  @objc static func readerBackgroundDarkColor() -> UIColor {
    return UIColor(white: 5.0/255.0, alpha: 1.0)
  }

  @objc static func readerBackgroundSepiaColor() -> UIColor {
    return UIColor(red: 250.0/255.0, green: 244.0/255.0, blue: 232.0/255.0, alpha: 1.0)
  }

  @objc static func backgroundMediaOverlayHighlightColor() -> UIColor {
    return .yellow
  }

  @objc static func backgroundMediaOverlayHighlightDarkColor() -> UIColor {
    return .orange
  }

  @objc static func backgroundMediaOverlayHighlightSepiaColor() -> UIColor {
    return .yellow
  }

  @objc static func systemFontFamilyName() -> String {
    return "OpenSans"
  }

  @objc static func systemFontName() -> String {
    return "OpenSans-Regular"
  }

  @objc static func semiBoldSystemFontName() -> String {
    return "OpenSans-SemiBold"
  }

  @objc static func boldSystemFontName() -> String {
    return "OpenSans-Bold"
  }

  @objc static func defaultTOCRowHeight() -> CGFloat {
    return 56
  }

  @objc static func defaultBookmarkRowHeight() -> CGFloat {
    return 100
  }

  @objc static func defaultAppearance() -> UINavigationBarAppearance {
    return appearance(withBackgroundColor: backgroundColor())
  }

  @objc static func appearance(withBackgroundColor backgroundColor: UIColor) -> UINavigationBarAppearance {
    let appearance = UINavigationBarAppearance()
    appearance.configureWithOpaqueBackground()
    appearance.backgroundColor = backgroundColor
    appearance.titleTextAttributes = [
      .font: UIFont.semiBoldPalaceFont(ofSize: 18.0)
    ]
    return appearance
  }
}
