//
//  SignInModalView.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import SwiftUI

/// SwiftUI sign-in modal that wraps AccountDetailView for use in checkout/borrow flows
struct SignInModalView: View {
  let libraryAccountID: String
  let completion: (() -> Void)?
  @Environment(\.dismiss) private var dismiss
  @StateObject private var accountPublisher = UserAccountPublisher.shared
  
  var body: some View {
    NavigationView {
      AccountDetailView(libraryAccountID: libraryAccountID)
        .navigationTitle(Strings.Generic.signin)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarItems(leading: cancelButton)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color(UIColor.systemGroupedBackground), for: .navigationBar)
        .onChange(of: accountPublisher.hasCredentials) { hasCredentials in
          // Auto-dismiss when user successfully signs in
          if hasCredentials {
            dismiss()
            completion?()
          }
        }
    }
    .navigationViewStyle(.stack)
  }
  
  private var cancelButton: some View {
    Button(Strings.Generic.cancel) {
      dismiss()
    }
  }
}

/// Bridge class to present SignInModalView from Objective-C
@objcMembers
class SignInModalPresenter: NSObject {
  
  /// Presents the SwiftUI sign-in modal
  /// - Parameters:
  ///   - libraryAccountID: The library account to sign into
  ///   - completion: Called when sign-in completes successfully
  static func presentSignInModal(libraryAccountID: String, completion: (() -> Void)?) {
    let view = SignInModalView(
      libraryAccountID: libraryAccountID,
      completion: completion
    )
    
    let vc = UIHostingController(rootView: view)
    vc.modalPresentationStyle = .formSheet
    
    TPPPresentationUtils.safelyPresent(vc, animated: true)
  }
  
  /// Convenience method for current account
  /// - Parameter completion: Called when sign-in completes successfully
  static func presentSignInModalForCurrentAccount(completion: (() -> Void)?) {
    guard let libraryID = AccountsManager.shared.currentAccountId else {
      completion?()
      return
    }
    
    presentSignInModal(libraryAccountID: libraryID, completion: completion)
  }
}
