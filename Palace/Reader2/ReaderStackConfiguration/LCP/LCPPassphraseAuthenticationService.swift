#if LCP

import Foundation
import ReadiumLCP
import PalaceCatalog

/**
 For Passphrase in License Document, see https://readium.org/lcp-specs/releases/lcp/latest#41-introduction
 */
class LCPPassphraseAuthenticationService: LCPAuthenticating {

    private let bookRegistry: TPPBookRegistryProvider
    private let accountsManager: AccountsManager
    private let networkExecutor: TPPNetworkExecutor
    private let settings: TPPSettings

    init(
        bookRegistry: TPPBookRegistryProvider = AppContainer.production().bookRegistry,
        accountsManager: AccountsManager = AppContainer.production().accountsManager,
        networkExecutor: TPPNetworkExecutor = AppContainer.production().networkExecutor,
        settings: TPPSettings = AppContainer.production().settings
    ) {
        self.bookRegistry = bookRegistry
        self.accountsManager = accountsManager
        self.networkExecutor = networkExecutor
        self.settings = settings
    }

    private func retrievePassphraseFromLoan(for license: LCPAuthenticatedLicense, reason: LCPAuthenticationReason, allowUserInteraction: Bool, sender: Any?) async -> String? {
        let licenseId = license.document.id
        let registry = bookRegistry

        // PHASE 1 (swarm_81b5099e Bucket A): LCP passphrase retrieval is on
        // the critical path for LCP-protected book open. Block on
        // `Account.awaitReady()` before reading `loansUrl`; pre-Phase-1 this
        // read `currentAccount?.loansUrl` directly and returned nil during
        // the cold-launch window — which then surfaced as "LCP open failed"
        // to the user even though the only problem was the auth document
        // hadn't loaded yet. Function was already `async`; per the ADR's
        // single-timeout policy the existing LCP fulfillment timeout covers
        // this — no withTimeout wrapper added here.
        guard let currentAccount = accountsManager.currentAccount else {
            return nil
        }
        let details: AccountDetails
        do {
            details = try await currentAccount.awaitReady()
        } catch {
            return nil
        }
        guard let loansUrl = details.loansUrl else {
            return nil
        }

        let logError = makeLogger(code: .lcpPassphraseRetrievalFail, urlKey: "loansUrl", urlValue: loansUrl)
        guard let book = registry.myBooks.first(where: { registry.fulfillmentId(forIdentifier: $0.identifier) == licenseId }) else {
            logError("LCP passphrase retrieval error: no book with fulfillment id found", "licenseId", licenseId)
            return nil
        }

        do {
            let (data, _) = try await networkExecutor.GET(loansUrl, useTokenIfAvailable: true)

            guard let xml = TPPXML.xml(withData: data),
                  case let entries = xml.childrenWithName("entry"), !entries.isEmpty else {
                logError("LCP passphrase retrieval error: loans XML parsing failed", "responseBody", String(data: data, encoding: .utf8) ?? "N/A")
                return nil
            }

            for entry in entries {
                if let entryId = entry.firstChild(withName: "id")?.value, entryId == book.identifier {

                    // Iterate through all 'link' elements in the entry
                    let links = entry.childrenWithName("link")
                    if links.isEmpty {
                        continue
                    }

                    for link in links {

                        // Iterate through all children of the link to find 'hashed_passphrase'
                        if let children = link.children as? [TPPXML], !children.isEmpty {
                            for child in children {

                                if child.name == "hashed_passphrase", !child.value.isEmpty {
                                    return child.value
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
            return nil
        }

        let logError = makeLogger(code: .lcpPassphraseAuthorizationFail, urlKey: "hintUrl", urlValue: hintURL)
        do {
            let (data, _) = try await networkExecutor.GET(hintURL)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let passphrase = json["passphrase"] as? String {
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

        if settings.enterLCPPassphraseManually {
            return await withCheckedContinuation { continuation in
                // `withCheckedContinuation` runs its body synchronously on the caller's
                // executor, which for this `nonisolated async` method is the generic
                // cooperative pool — NOT guaranteed main. A bare `MainActor.assumeIsolated`
                // would be unsound. Hop the UIKit alert build+present onto main explicitly.
                // The continuation is captured by the action handlers and resumed there
                // (on main, from the tapped button), so the resume semantics are preserved.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
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
                }
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
