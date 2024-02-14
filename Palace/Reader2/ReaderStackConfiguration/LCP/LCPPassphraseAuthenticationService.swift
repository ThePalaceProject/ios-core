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
    if TPPSettings.shared.enterLCPPassphraseManually {
      requestPassphrase(for: license, reason: reason, allowUserInteraction: allowUserInteraction, sender: sender, completion: completion)
    } else {
      retrievePassphraseFromLoan(for: license, reason: reason, allowUserInteraction: allowUserInteraction, sender: sender, completion: completion)
    }
  }

  /// Retrieves LCP passphrase from loans
  private func retrievePassphraseFromLoan(for license: LCPAuthenticatedLicense, reason: LCPAuthenticationReason, allowUserInteraction: Bool, sender: Any?, completion: @escaping (String?) -> Void) {
    let licenseId = license.document.id
    let registry = TPPBookRegistry.shared
    guard let loansUrl = AccountsManager.shared.currentAccount?.loansUrl else {
      completion(nil)
      return
    }
    let logError = makeLogger(code: .lcpPassphraseRetrievalFail, urlKey: "loansUrl", urlValue: loansUrl)
    guard let book = registry.myBooks.filter({ registry.fulfillmentId(forIdentifier: $0.identifier) == licenseId }).first else {
            logError("LCP passphrase retrieval error: no book with fulfillment id found", "licenseId", licenseId)
            completion(nil)
            return
    }
    TPPNetworkExecutor.shared.GET(loansUrl, useTokenIfAvailable: false) { result in
      switch result {
      case .success(let data, _):
        let responseBody = String(data: data, encoding: .utf8)
        guard let xml = TPPXML(data: data),
              let entries = xml.children(withName: "entry") as? [TPPXML]
        else {
          logError("LCP passphrase retrieval error: loans XML parsing failed", "responseBody", responseBody ?? "N/A")
          completion(nil)
          return
        }
        // Iterate over feed entries;
        // looking for an entry containing book identifier
        for entry in entries {
          if let entryId = entry.firstChild(withName: "id")?.value, entryId == book.identifier {
            guard let links = (entry.children as? [TPPXML])?.filter({ $0.name == "link" }) else {
              continue
            }
            // Each entry contains different links; looking for one with "lcp:hashed_passphrase" node.
            for link in links {
              if let passphrase = link.firstChild(withName: "hashed_passphrase")?.value {
                completion(passphrase)
                return
              }
            }
          }
        }
        // Passphrase was not found
        logError("LCP passphrase retrieval error: passphrase not found for \(book.identifier)", "responseBody", responseBody ?? "N/A" )
      case .failure(let error, _):
        logError("LCP passphrase retrieval error", NSUnderlyingErrorKey, error)
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
    let logError = makeLogger(code: .lcpPassphraseAuthorizationFail, urlKey: "hintUrl", urlValue: hintURL)
    TPPNetworkExecutor.shared.GET(hintURL) { (result) in
      switch result {
      case .success(let data, _):
        if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String:Any],
          let passphrase = json?["passphrase"] as? String {
          completion(passphrase)
        } else {
          let responseBody = String(data: data, encoding: .utf8)
          logError("LCP Passphrase JSON Parse Error", "responseBody", responseBody ?? "N/A")
          completion(nil)
        }
      case .failure(let error, _):
        logError("Unable to retrieve LCP passphrase", NSUnderlyingErrorKey, error)
        completion(nil)
      }
    }
  }
  
  /// Enter LCP passphrase manually
  private func requestPassphrase(for license: LCPAuthenticatedLicense, reason: LCPAuthenticationReason, allowUserInteraction: Bool, sender: Any?, completion: @escaping (String?) -> Void) {
    var passphraseField: UITextField?
    let ac = UIAlertController(title: "Enter LCP Passphrase", message: license.hint, preferredStyle: .alert)
    let doneAction = UIAlertAction(title: "Done", style: .default) { action in
      completion(passphraseField?.text)
    }
    let cancelAction = UIAlertAction(title: "Cancel", style: .cancel) { action in
      completion(nil)
    }
    ac.addAction(doneAction)
    ac.addAction(cancelAction)
    ac.addTextField { textField in
      textField.placeholder = "Passphrase"
      textField.autocapitalizationType = .none
      textField.autocorrectionType = .no
      textField.spellCheckingType = .no
      textField.keyboardType = .default
      textField.returnKeyType = .done
      textField.isSecureTextEntry = true
      passphraseField = textField
    }
    TPPAlertUtils.presentFromViewControllerOrNil(alertController: ac, viewController: nil, animated: true, completion: nil)
  }
    
  /// Creates a logger function
  /// - Parameters:
  ///   - code: `TPPErrorCode` code
  ///   - urlKey: URL key for `TPPErrorLogger` metadata
  ///   - urlValue: URL value for `TPPErrorLogger` metadata
  /// - Returns: function `(_ summary: String, _ errorKey: String, _ errorValue: Any) -> Void`
  ///
  /// Creates an error logging function with parameters:
  ///   - `summary` - searchable summary for Crashlytics
  ///   - `errorKey` - error key value (e.g, `NSUnderlyingErrorKey`, or any string key for the error) for `TPPErrorLogger` metadata
  ///   - `errorValue` - error value for `TPPErrorLogger` metadata
  private func makeLogger(code: TPPErrorCode, urlKey: String, urlValue: URL) -> (_ summary: String, _ errorKey: String, _ errorValue: Any) -> Void {
    func logError(summary: String, errorKey: String, errorValue: Any) -> Void {
      TPPErrorLogger.logError(
        withCode: code,
        summary: summary,
        metadata: [
          urlKey: urlValue,
          errorKey: errorValue
        ]
      )
    }
    return logError
  }
}

#endif
