//
//  LCPPassphraseAuthenticationService.swift
//  The Palace Project
//
//  Created by Ernest Fan on 2021-02-08.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

#if LCP

import Foundation
import ReadiumLCP

/**
 For Passphrase in License Document, see https://readium.org/lcp-specs/releases/lcp/latest#41-introduction
 */
class LCPPassphraseAuthenticationService: LCPAuthenticating {
  func retrievePassphrase(for license: LCPAuthenticatedLicense, reason: LCPAuthenticationReason, allowUserInteraction: Bool, sender: Any?, completion: @escaping (String?) -> Void) {
    guard let hintLink = license.hintLink,
      let hintURL = URL(string: hintLink.href) else {
      Log.error(#file, "LCP Authenticated License does not contain valid hint link")
      completion(nil)
      return
    }
    
    TPPNetworkExecutor.shared.GET(hintURL) { (result) in
      switch result {
      case .success(let data, _):
        if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String:Any],
          let passphrase = json?["passphrase"] as? String {
          completion(passphrase)
        } else {
          let responseBody = String(data: data, encoding: .utf8)
          TPPErrorLogger.logError(
            withCode: .lcpPassphraseAuthorizationFail,
            summary: "LCP Passphrase JSON Parse Error",
            metadata: [
              "hintUrl": hintURL,
              "responseBody": responseBody ?? "N/A",
          ])
          completion(nil)
        }
      case .failure(let error, _):
        TPPErrorLogger.logError(
          withCode: .lcpPassphraseAuthorizationFail,
          summary: "Unable to retrieve LCP passphrase",
          metadata: [
            NSUnderlyingErrorKey: error,
            "hintUrl": hintURL,
        ])
        completion(nil)
      }
    }
  }
}

#endif
