import UIKit
import WebKit

class TPPSAMLHelper {

  var businessLogic: TPPSignInBusinessLogic!

  func logIn(loginCancelHandler: @escaping () -> Void) {
    Log.info(#file, "🔐 [SAML] logIn() called")
    Log.info(#file, "🔐 [SAML] Library account ID: \(businessLogic.libraryAccountID)")
    
    guard let idpURL = businessLogic.selectedIDP?.url else {
      Log.error(#file, "🔐 [SAML] ERROR: No IDP URL available - selectedIDP is nil or has no URL")
      return
    }
    
    Log.info(#file, "🔐 [SAML] IDP URL: \(idpURL.absoluteString)")
    Log.info(#file, "🔐 [SAML] IDP Display Name: \(businessLogic.selectedIDP?.displayName ?? "N/A")")

    var urlComponents = URLComponents(url: idpURL, resolvingAgainstBaseURL: true)
    let redirectURI = URLQueryItem(name: "redirect_uri", value: businessLogic.urlSettingsProvider.universalLinksURL.absoluteString)
    urlComponents?.queryItems?.append(redirectURI)
    
    Log.info(#file, "🔐 [SAML] Redirect URI: \(businessLogic.urlSettingsProvider.universalLinksURL.absoluteString)")
    
    guard let url = urlComponents?.url else {
      Log.error(#file, "🔐 [SAML] ERROR: Failed to construct final URL from components")
      return
    }
    
    Log.info(#file, "🔐 [SAML] Final login URL: \(url.absoluteString)")

    let loginCompletionHandler: (URL, [HTTPCookie]) -> Void = { url, cookies in
      Log.info(#file, "🔐 [SAML] ✅ Login completion handler called")
      Log.info(#file, "🔐 [SAML] Redirect URL received: \(url.absoluteString)")
      Log.info(#file, "🔐 [SAML] Cookies received: \(cookies.count)")
      for (index, cookie) in cookies.enumerated() {
        Log.debug(#file, "🔐 [SAML]   Cookie[\(index)]: \(cookie.name)=\(cookie.value.prefix(20))... domain=\(cookie.domain)")
      }
      
      self.businessLogic.cookies = cookies
      Log.info(#file, "🔐 [SAML] Stored \(cookies.count) cookies in businessLogic")

      let redirectNotification = Notification(name: .TPPAppDelegateDidReceiveCleverRedirectURL, object: url, userInfo: nil)
      Log.info(#file, "🔐 [SAML] Calling handleRedirectURL()...")
      
      self.businessLogic.handleRedirectURL(redirectNotification) { error, errorTitle, errorMessage in
        Log.info(#file, "🔐 [SAML] handleRedirectURL completion called")
        if let error = error {
          Log.error(#file, "🔐 [SAML] ❌ handleRedirectURL returned error: \(error.localizedDescription)")
          Log.error(#file, "🔐 [SAML]   Error title: \(errorTitle ?? "nil")")
          Log.error(#file, "🔐 [SAML]   Error message: \(errorMessage ?? "nil")")
        } else {
          Log.info(#file, "🔐 [SAML] ✅ handleRedirectURL completed successfully (no error)")
        }
        
        DispatchQueue.main.async {
          Log.info(#file, "🔐 [SAML] Dismissing WebView...")
          self.businessLogic.uiDelegate?.dismiss(animated: true) {
            Log.info(#file, "🔐 [SAML] WebView dismissed")
            if let error = error, let errorTitle = errorTitle, let errorMessage = errorMessage {
              Log.error(#file, "🔐 [SAML] Presenting validation error to user")
              self.businessLogic.uiDelegate?.businessLogic(self.businessLogic, didEncounterValidationError: error, userFriendlyErrorTitle: errorTitle, andMessage: errorMessage)
            }
          }
        }
      }
    }
    
    let loginCancelWrapper: () -> Void = {
      Log.info(#file, "🔐 [SAML] ⚠️ Login cancelled by user")
      loginCancelHandler()
    }

    let model = TPPCookiesWebViewModel(
      cookies: [],
      request: URLRequest(url: url),
      loginCompletionHandler: loginCompletionHandler,
      loginCancelHandler: loginCancelWrapper,
      bookFoundHandler: nil,
      problemFoundHandler: nil,
      autoPresentIfNeeded: false
    )

    let cookiesVC = TPPCookiesWebViewController(model: model)
    let navigationWrapper = UINavigationController(rootViewController: cookiesVC)

    Log.info(#file, "🔐 [SAML] Presenting SAML WebView controller...")
    businessLogic.uiDelegate?.present(navigationWrapper, animated: true, completion: {
      Log.info(#file, "🔐 [SAML] SAML WebView presented successfully")
    })
  }
}
