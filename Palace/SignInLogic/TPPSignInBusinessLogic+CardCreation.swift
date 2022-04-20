//
//  TPPSignInBusinessLogic+CardCreation.swift
//  Palace
//
//  Created by Vladimir Fedorov on 07.04.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

extension TPPSignInBusinessLogic {
  /// The entry point to the regular card creation flow.
  /// - Parameters:
  ///   - completion: Always called whether the library supports
  ///   card creation or not. If it's possible, the handler returns
  ///   a navigation controller containing the VCs for the whole flow.
  ///   All the client has to do is to present this navigation controller
  ///   in whatever way it sees fit.
  @objc
  func startRegularCardCreation(completion: @escaping (UINavigationController?, Error?) -> Void) {
    // If the library does not have a sign-up url, there's nothing we can do
    guard let signUpURL = libraryAccount?.details?.signUpUrl else {
      let description = NSLocalizedString("We're sorry. Currently we do not support signups for new patrons via the app.", comment: "Message describing the fact that new patron sign up is not supported by the current selected library")
      let error = NSError(domain: TPPErrorLogger.clientDomain,
                          code: TPPErrorCode.nilSignUpURL.rawValue,
                          userInfo: [
                            NSLocalizedDescriptionKey: description])
      TPPErrorLogger.logError(withCode: .nilSignUpURL,
                               summary: "SignUp Error in Settings: nil signUp URL",
                               metadata: [
                                "libraryAccountUUID": libraryAccountID,
                                "libraryAccountName": libraryAccount?.name ?? "N/A",
      ])
      completion(nil, error)
      return
    }
    
    
    let title = NSLocalizedString("eCard",
                                  comment: "Title for web-based card creator page")
    let msg = NSLocalizedString("We're sorry. Our sign up system is currently down. Please try again later.",
                                comment: "Message for error loading the web-based card creator")
    let webVC = RemoteHTMLViewController(URL: signUpURL,
                                         title: title,
                                         failureMessage: msg)
    completion(UINavigationController(rootViewController: webVC), nil)
  }
}
