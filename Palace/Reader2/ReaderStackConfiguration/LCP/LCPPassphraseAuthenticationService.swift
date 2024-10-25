#if LCP

import Foundation
import ReadiumLCP

/**
 For Passphrase in License Document, see https://readium.org/lcp-specs/releases/lcp/latest#41-introduction
 */
class LCPPassphraseAuthenticationService: LCPAuthenticating {

  private func retrievePassphraseFromLoan(for license: LCPAuthenticatedLicense, reason: LCPAuthenticationReason, allowUserInteraction: Bool, sender: Any?) async -> String? {
    let licenseId = license.document.id
    let registry = TPPBookRegistry.shared
    guard let loansUrl = AccountsManager.shared.currentAccount?.loansUrl else {
      return nil
    }

    let logError = makeLogger(code: .lcpPassphraseRetrievalFail, urlKey: "loansUrl", urlValue: loansUrl)
    guard let book = registry.myBooks.first(where: { registry.fulfillmentId(forIdentifier: $0.identifier) == licenseId }) else {
      logError("LCP passphrase retrieval error: no book with fulfillment id found", "licenseId", licenseId)
      return nil
    }

    do {
      let (data, _) = try await TPPNetworkExecutor.shared.GET(loansUrl, useTokenIfAvailable: true)
      guard let xml = TPPXML(data: data),
            let entries = xml.children(withName: "entry") as? [TPPXML] else {
        logError("LCP passphrase retrieval error: loans XML parsing failed", "responseBody", String(data: data, encoding: .utf8) ?? "N/A")
        return nil
      }

      for entry in entries {
        if let entryId = entry.firstChild(withName: "id")?.value, entryId == book.identifier {

          // Iterate through all 'link' elements in the entry
          let links = entry.children(withName: "link") as? [TPPXML] ?? []
          if links.isEmpty {
            continue
          }

          for link in links {

            // Iterate through all children of the link to find 'hashed_passphrase'
            if let children = link.children as? [TPPXML], !children.isEmpty {
              for child in children {

                if child.name == "hashed_passphrase", let passphrase = child.value {
                  return passphrase
                }
              }
            }
          }
        }
      }

      logError("LCP passphrase retrieval error: passphrase not found for \(book.identifier)", "responseBody", String(data: data, encoding: .utf8) ?? "N/A")
    } catch {
      logError("LCP passphrase retrieval error", NSUnderlyingErrorKey, error)
    }

    return nil
  }

  /// Retrieves LCP passphrase from hint URL in the license (async version)
  private func retrievePassphraseFromHint(for license: LCPAuthenticatedLicense, reason: LCPAuthenticationReason, allowUserInteraction: Bool, sender: Any?) async -> String? {
    guard let hintLink = license.hintLink,
          let hintURL = URL(string: hintLink.href) else {
      Log.error(#file, "LCP Authenticated License does not contain valid hint link")
      return nil
    }

    let logError = makeLogger(code: .lcpPassphraseAuthorizationFail, urlKey: "hintUrl", urlValue: hintURL)
    do {
      let (data, _) = try await TPPNetworkExecutor.shared.GET(hintURL)
      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let passphrase = json?["passphrase"] as? String {
        return passphrase
      } else {
        logError("LCP Passphrase JSON Parse Error", "responseBody", String(data: data, encoding: .utf8) ?? "N/A")
      }
    } catch {
      logError("Unable to retrieve LCP passphrase", NSUnderlyingErrorKey, error)
    }
    return nil
  }

  /// Requests the passphrase from the user manually (async version)
  func retrievePassphrase(for license: ReadiumLCP.LCPAuthenticatedLicense, reason: ReadiumLCP.LCPAuthenticationReason, allowUserInteraction: Bool, sender: Any?) async -> String? {

    if TPPSettings.shared.enterLCPPassphraseManually {
      return await withCheckedContinuation { continuation in
        var passphraseField: UITextField?
        let ac = UIAlertController(title: "Enter LCP Passphrase", message: license.hint, preferredStyle: .alert)

        let doneAction = UIAlertAction(title: "Done", style: .default) { _ in
          continuation.resume(returning: passphraseField?.text)
        }

        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel) { _ in
          continuation.resume(returning: nil)
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
    } else {
      return await retrievePassphraseFromLoan(for: license, reason: reason, allowUserInteraction: allowUserInteraction, sender: sender)
    }
  }

  /// Creates a logger function
  private func makeLogger(code: TPPErrorCode, urlKey: String, urlValue: URL) -> (_ summary: String, _ errorKey: String, _ errorValue: Any) -> Void {
    func logError(summary: String, errorKey: String, errorValue: Any) {
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
