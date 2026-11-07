//
//  DLNavigator.swift
//  Palace
//
//  Created by Vladimir Fedorov on 12/05/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import Combine
import FirebaseDynamicLinks
import PalaceBookRegistry

/// No stored state — all members are methods over the passed-in `DynamicLink`,
/// so the type is trivially `Sendable`; `final` pins that (no subclass can add
/// mutable state). Lets `static let shared` be concurrency-safe without an
/// isolation annotation.
final class DLNavigator: Sendable {

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
    /// `@MainActor`: routes into the UIKit-driving `login(...)` path.
    @MainActor
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
    @MainActor
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

    // `@MainActor`: drives UIKit throughout (`UIApplication.shared.delegate`,
    // `topViewController()`, `present(_:animated:)`) and the `@MainActor`
    // `SignInModalSheetPresenter`. Confining the method to the main actor is the
    // isolation-only fix for the `complete`-mode "main-actor API from nonisolated
    // context" warnings on the UIKit accesses below, with no behavior change (the
    // body already hopped to main via `DispatchQueue.main.async` / `Task { @MainActor }`).
    @MainActor
    private func login(libraryId: String, barcode: String, accountsManager: AccountsManager = AppContainer.production().accountsManager) {
        let accountsManager = accountsManager
        guard let topViewController = (UIApplication.shared.delegate as? TPPAppDelegate)?.topViewController(),
              let newAccount = accountsManager.account(libraryId)
        else {
            Self.retryLoginWhenCatalogLoads(accountsManager: accountsManager) { [weak self] in
                self?.login(libraryId: libraryId, barcode: barcode)
            }
            return
        }
        if newAccount.uuid != accountsManager.currentAccount?.uuid {
            Self.callOnce(on: accountsManager.currentLibraryChangePublisher) { [weak self] in
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
            // Uses the container's `SignInModalSheetPresenter` so SwiftUI
            // consumers and test seams observe the same instance.
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

    /// Retries a deep-link sign-in after the next catalog load, for a link that
    /// names a library the registry has not loaded yet.
    @MainActor
    static func retryLoginWhenCatalogLoads(
        accountsManager: AccountsManager,
        retry: @escaping @MainActor @Sendable () -> Void
    ) {
        callOnce(on: accountsManager.catalogLoadedPublisher, block: retry)
    }

    /// Runs `block` on the first value `changes` emits, then unsubscribes.
    /// `AccountsManager`'s publishers deliver on main, so `block` runs on the
    /// main actor without a further hop. Callers do not keep the subscription;
    /// the helper does, until the first value.
    static func callOnce<Output>(
        on changes: AnyPublisher<Output, Never>,
        block: @escaping @MainActor @Sendable () -> Void
    ) {
        // The subscription keeps the box, and so itself, alive until the first
        // value, then releases both.
        let box = SubscriptionBox()
        box.subscription = changes.first().sink { _ in
            box.subscription = nil
            MainActor.assumeIsolated {
                block()
            }
        }
    }
}

/// Holds the one-shot subscription made by `callOnce(on:block:)`. Written when
/// the subscription is made and cleared when it fires, both on the main thread.
private final class SubscriptionBox: @unchecked Sendable {
    var subscription: AnyCancellable?
}
