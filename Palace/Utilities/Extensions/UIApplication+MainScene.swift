import UIKit

extension UIApplication {

  /// The primary `UIWindowScene` for the device screen.
  ///
  /// Filters out CarPlay and external-display scenes so that code
  /// referencing "the app window" always targets the user's device,
  /// even when AirPlay mirroring or Zoom screen-sharing creates
  /// an additional connected scene.
  var mainWindowScene: UIWindowScene? {
    connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.session.role == .windowApplication }
  }

  /// The key window on the main device scene.
  var mainKeyWindow: UIWindow? {
    mainWindowScene?.windows.first { $0.isKeyWindow }
  }
}
