//
//  AdvancedSettingsView.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import SwiftUI

struct AdvancedSettingsView: View {
  typealias DisplayStrings = Strings.TPPSettingsAdvancedViewController
  
  let account: Account
  @State private var showDeleteAlert = false
  @Environment(\.dismiss) private var dismiss
  
  init(accountID: String) {
    self.account = AccountsManager.shared.account(accountID)!
  }
  
  var body: some View {
    List {
      Section {
        Button(action: { showDeleteAlert = true }) {
          Text(DisplayStrings.deleteServerData)
            .font(.system(.body))
            .foregroundColor(.red)
        }
      }
    }
    .listStyle(GroupedListStyle())
    .navigationTitle(DisplayStrings.advanced)
    .navigationBarTitleDisplayMode(.inline)
    .alert(deleteAlertTitle, isPresented: $showDeleteAlert) {
      Button(Strings.Generic.delete, role: .destructive) {
        disableSync()
      }
      Button(Strings.Generic.cancel, role: .cancel) {}
    } message: {
      Text(deleteMessage)
    }
  }
  
  private var deleteAlertTitle: String {
    NSLocalizedString("Delete Server Data", comment: "")
  }
  
  private var deleteMessage: String {
    String.localizedStringWithFormat(
      NSLocalizedString("Selecting \"Delete\" will remove all bookmarks from the server for %@.", comment: ""),
      account.name
    )
  }
  
  private func disableSync() {
    account.details?.syncPermissionGranted = false
    dismiss()
  }
}

