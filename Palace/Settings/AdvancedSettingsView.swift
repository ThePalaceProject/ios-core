//
//  AdvancedSettingsView.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import SwiftUI

struct AdvancedSettingsView: View {
  typealias DisplayStrings = Strings.Settings
  
  let account: Account
  @State private var showDeleteAlert = false
  @Environment(\.dismiss) private var dismiss
  
  init(accountID: String) {
    guard let account = AccountsManager.shared.account(accountID) else {
      fatalError("Account not found for ID: \(accountID)")
    }
    self.account = account
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
    .alert(DisplayStrings.deleteServerData, isPresented: $showDeleteAlert) {
      Button(Strings.Generic.delete, role: .destructive, action: disableSync)
      Button(Strings.Generic.cancel, role: .cancel) {}
    } message: {
      Text(Strings.AccountDetail.deleteServerDataMessage(libraryName: account.name))
    }
  }
  
  private func disableSync() {
    account.details?.syncPermissionGranted = false
    dismiss()
  }
}

