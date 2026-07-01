//
//  DLNavigator.swift
//  Palace
//
//  Created by Vladimir Fedorov on 12/05/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import FirebaseDynamicLinks

class DLNavigator {

    typealias Destination = (screen: String, params: [String: String])

    static let shared = DLNavigator()

    /// Checks if DLNavigator can parse the link
    /// - Parameter dynamicLink: Firebase dynamic link
    /// - Returns: `true` if DLNavigator supports parameters provided with the link
    func isValidLink(_ dynamicLink: DynamicLink) -> Bool {
        if let parsedData = parseLink(dynamicLink), !parsedData.screen.isEmpty {
            return true
        }
        return false
    }

    /// Navigates to the screen in the link
    /// - Parameter dynamicLink: Firebase dynamic link
    func navigate(to dynamicLink: DynamicLink) {
        guard let destination = parseLink(dynamicLink) else {
            return
        }
        navigate(to: destination.screen, params: destination.params)
    }

    /// Navigates to the screen with the provided parameters
    /// - Parameters:
    ///   - screen: `screen` parameter
    ///   - params: dynamic link parameters
    func navigate(to screen: String, params: [String: String]) {
        switch screen {
        case "login":
            if let libraryId = params["libraryid"], let barcode = params["barcode"] {
                login(libraryId: libraryId, barcode: barcode)
            }
        default: break
        }
    }

    private func parseLink(_ dynamicLink: DynamicLink) -> Destination? {
        guard let url = dynamicLink.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let screen = components.queryItems?.first(where: { $0.name.lowercased() == "screen" })?.value?.lowercased() as? String
        else {
            return nil
        }
        var params = [String: String]()
        components.queryItems?.forEach { params[$0.name.lowercased()] = $0.value }
        return Destination(screen: screen, params: params )
    }

    private func login(libraryId: String, barcode: String, accountsManager: AccountsManager = AppContainer.production().accountsManager) {
        let accountsManager = accountsManager
        guard let topViewController = (UIApplication.shared.delegate as? TPPAppDelegate)?.topViewController(),
              let newAccount = accountsManager.account(libraryId)
        else {
            callOnce(on: .TPPAccountSetDidLoad) { [weak self] _ in
                self?.login(libraryId: libraryId, barcode: barcode)
            }
            return
        }
        if newAccount.uuid != accountsManager.currentAccount?.uuid {
            callOnce(on: .TPPCurrentAccountDidChange) { [weak self] _ in
                self?.login(libraryId: libraryId, barcode: barcode)
            }
            DispatchQueue.main.async {
                MyBooksViewModel(appContainer: .production()).authenticateAndLoad(account: newAccount)
            }
            return
        }
        if accountsManager.userAccount(for: libraryId).isSignedIn() {
            return
        }
        Task { @MainActor in
            // swarm_d8f11437 Module A wave 4 — migrated from static
            // `SignInModalPresenter.presentSignInModalForCurrentAccount`
            // to the AppContainer-injected `SignInModalSheetPresenter` so
            // SwiftUI consumers and test seams observe the same instance.
            AppContainer.production().signInModalSheetPresenter
                .presentSignInModalForCurrentAccount {
                    let accountList = TPPAccountList { account in
                        MyBooksViewModel(appContainer: .production()).authenticateAndLoad(account: account)
                    }
                    let nav = UINavigationController(rootViewController: accountList)
                    topViewController.present(nav, animated: true)
                }
        }
    }

    /// Runs `block` when receives a notification with `name` once.
    /// - Parameters:
    ///   - name: Notification name
    ///   - block: Code to run
    private func callOnce(on name: Notification.Name, block: @escaping (_ notification: Notification) -> Void) {
        // Mirror `ObserverTokenBox` (TPPBookRegistry.swift): a self-removing
        // `@Sendable` observer block can't reference a `var token` assigned after
        // the block is formed — the `targeted` checker rejects it as "'token'
        // mutated after capture by sendable closure". The box's `token` is
        // written exactly once (right after `addObserver` returns) and only read
        // thereafter, so `@unchecked Sendable` documents write-once-then-read
        // confinement, not a race waiver.
        let box = ObserverTokenBox()
        box.token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
            box.removeObserver(name: name)
            block(notification)
        }
    }
}

/// Sendable holder for a `NotificationCenter` observer token (see `callOnce`).
/// Written exactly once after `addObserver` returns, read-only thereafter —
/// write-once-then-read confinement, no race.
private final class ObserverTokenBox: @unchecked Sendable {
    var token: NSObjectProtocol?
    func removeObserver(name: Notification.Name) {
        if let token {
            NotificationCenter.default.removeObserver(token, name: name, object: nil)
        }
    }
}
