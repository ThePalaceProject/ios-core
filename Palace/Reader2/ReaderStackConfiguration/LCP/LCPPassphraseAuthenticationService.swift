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
    retrievePassphraseFromLoan(for: license, reason: reason, allowUserInteraction: allowUserInteraction, sender: sender, completion: completion)
  }

  /// Retrieves LCP passphrase from loans
  private func retrievePassphraseFromLoan(for license: LCPAuthenticatedLicense, reason: LCPAuthenticationReason, allowUserInteraction: Bool, sender: Any?, completion: @escaping (String?) -> Void) {
    let licenseId = license.document.id
    let registry = TPPBookRegistry.shared()
    guard let loansUrl = AccountsManager.shared.currentAccount?.loansUrl else {
      completion(nil)
      return
    }
    guard let books = registry.myBooks as? [TPPBook],
          let book = books.filter({ registry.fulfillmentId(forIdentifier: $0.identifier) == licenseId }).first else {
            Log.error(#file, "LCP passphrase retrieval failed, no book with fulfillment id=\(licenseId) found")
            completion(nil)
            return
    }
    TPPNetworkExecutor.shared.GET(loansUrl) { result in
      switch result {
      case .success(let data, _):
        let responseBody = String(data: data, encoding: .utf8)
        guard let xml = TPPXML(data: data),
              let entries = xml.children(withName: "entry") as? [TPPXML] else {
          TPPErrorLogger.logError(
            withCode: .lcpPassphraseRetrievalFail,
            summary: "LCP Passphrase Retrieval error: loans XML parsing failed",
            metadata: [
              "loansUrl": loansUrl,
              "responseBody": responseBody ?? "N/A"
            ]
          )
          completion(nil)
          return
        }
        for entry in entries {
          if let entryId = entry.firstChild(withName: "id")?.value, entryId == book.identifier {
            guard let links = (entry.children as? [TPPXML])?.filter({ $0.name == "link" }) else {
              continue
            }
            for link in links {
              if let passphrase = link.firstChild(withName: "hashed_passphrase")?.value {
                completion(passphrase)
                return
              }
            }
          }
        }
        // Passphrase was not found
        TPPErrorLogger.logError(
          withCode: .lcpPassphraseRetrievalFail,
          summary: "LCP Passphrase Retrieval error: passphrase not found for \(book.identifier)",
          metadata: [
            "loansUrl": loansUrl,
            "responseBody": responseBody ?? "N/A"
          ]
        )
      case .failure(let error, _):
        TPPErrorLogger.logError(
          withCode: .lcpPassphraseRetrievalFail,
          summary: "LCP Passphrase Retrieval Error",
          metadata: [
            "loansUrl": loansUrl,
            NSUnderlyingErrorKey: error
          ]
        )
        completion(nil)
      }
    }
    
  }
  /// Retrieves LCP passphrase from hint URL in the license
  private func retrievePassphraseFromHint(for license: LCPAuthenticatedLicense, reason: LCPAuthenticationReason, allowUserInteraction: Bool, sender: Any?, completion: @escaping (String?) -> Void) {
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
