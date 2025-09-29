import UIKit
import WebKit

class TPPSAMLHelper {
  var businessLogic: TPPSignInBusinessLogic!

  func logIn(loginCancelHandler: @escaping () -> Void) {
    guard let idpURL = businessLogic.selectedIDP?.url else {
      return
    }

    var urlComponents = URLComponents(url: idpURL, resolvingAgainstBaseURL: true)
    let redirectURI = URLQueryItem(
      name: "redirect_uri",
      value: businessLogic.urlSettingsProvider.universalLinksURL.absoluteString
    )
    urlComponents?.queryItems?.append(redirectURI)
    guard let url = urlComponents?.url else {
      // Handle error if URL creation failed
      return
    }

    let loginCompletionHandler: (URL, [HTTPCookie]) -> Void = { url, cookies in
      self.businessLogic.cookies = cookies

      let redirectNotification = Notification(
        name: .TPPAppDelegateDidReceiveCleverRedirectURL,
        object: url,
        userInfo: nil
      )
      self.businessLogic.handleRedirectURL(redirectNotification) { error, errorTitle, errorMessage in
        DispatchQueue.main.async {
          self.businessLogic.uiDelegate?.dismiss(animated: true) {
            if let error = error, let errorTitle = errorTitle, let errorMessage = errorMessage {
              self.businessLogic.uiDelegate?.businessLogic(
                self.businessLogic,
                didEncounterValidationError: error,
                userFriendlyErrorTitle: errorTitle,
                andMessage: errorMessage
              )
            }
          }
        }
      }
    }

    let model = TPPCookiesWebViewModel(
      cookies: [],
      request: URLRequest(url: url),
      loginCompletionHandler: loginCompletionHandler,
      loginCancelHandler: loginCancelHandler,
      bookFoundHandler: nil,
      problemFoundHandler: nil,
      autoPresentIfNeeded: false
    )

    let cookiesVC = TPPCookiesWebViewController(model: model)
    let navigationWrapper = UINavigationController(rootViewController: cookiesVC)

    businessLogic.uiDelegate?.present(navigationWrapper, animated: true, completion: nil)
  }
}
