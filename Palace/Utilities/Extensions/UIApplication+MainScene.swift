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

  /// A window that can actually host an `ASWebAuthenticationSession`.
  ///
  /// Every OIDC re-auth path needs this, and all three used to write
  /// `mainKeyWindow ?? ASPresentationAnchor()`. That fallback is the bug: a
  /// bare `ASPresentationAnchor()` is a `UIWindow` with NO scene, which is
  /// exactly what iOS rejects with `.presentationContextInvalid` (error 3).
  /// So the fallback manufactured the failure it existed to avoid — and
  /// `mainKeyWindow` is nil more often than it looks, because it requires a
  /// window currently reporting `isKeyWindow`, which none does during a modal
  /// dealloc or a tab transition.
  ///
  /// `windows.first` alone is not safe either: a scene's window list can carry
  /// keyboard, hidden, and non-`.normal`-level windows, and anchoring to one of
  /// those fails differently rather than better. Hence the filter.
  ///
  /// Returns nil rather than fabricating an anchor — callers decide what an
  /// unpresentable app state means. A caller that substitutes
  /// `ASPresentationAnchor()` has reintroduced the defect.
  var webAuthPresentationAnchor: UIWindow? {
    if let keyWindow = mainKeyWindow {
      return keyWindow
    }
    return mainWindowScene?.windows.first(where: UIApplication.isUsableWebAuthAnchor)
  }

  /// Whether a window can host a web-auth sheet.
  ///
  /// Hoisted out of the fallback above so tests call THIS rather than a copy.
  /// The first version of `WebAuthPresentationAnchorTests` declared its own
  /// duplicate of this predicate, so deleting a clause from production left
  /// every test green — including the one whose name claimed each clause was
  /// load-bearing. Two reviewers caught it independently. A test that restates
  /// the rule cannot detect the rule changing.
  ///
  /// Note this filter applies only to the FALLBACK: `mainKeyWindow` is returned
  /// unfiltered, because a window reporting `isKeyWindow` is by construction
  /// visible and presentable.
  static func isUsableWebAuthAnchor(_ window: UIWindow) -> Bool {
    !window.isHidden && window.windowLevel == .normal && window.rootViewController != nil
  }
}
