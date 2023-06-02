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
  
  private func login(libraryId: String, barcode: String) {
    let accountsManager = AccountsManager.shared
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
        MyBooksViewModel().authenticateAndLoad(newAccount)
      }
      return
    }
    if TPPUserAccount.sharedAccount(libraryUUID: libraryId).isSignedIn() {
      return
    }
    if let accountDetailVC = topViewController as? TPPSettingsAccountDetailViewController {
      accountDetailVC.setUserName(barcode)
    } else {
      TPPAccountSignInViewController.requestCredentials(forUsername: barcode, withCompletion: nil)
    }
  }
  
  /// Runs `block` when receives a notification with `name` once.
  /// - Parameters:
  ///   - name: Notification name
  ///   - block: Code to run
  private func callOnce(on name: Notification.Name, block: @escaping (_ notification: Notification) -> Void) {
    var token: NSObjectProtocol?
    token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
      NotificationCenter.default.removeObserver(token!, name: name, object: nil)
      block(notification)
    }
  }
}
