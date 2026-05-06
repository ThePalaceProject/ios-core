//
//  AdvancedSettingsView.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import SwiftUI

struct AdvancedSettingsView: View {
    typealias DisplayStrings = Strings.Settings

    let account: Account?
    @State private var showDeleteAlert = false
    @Environment(\.dismiss) private var dismiss

    init(accountID: String, accountsManager: AccountsManager = AccountsManager.shared) {
        self.account = accountsManager.account(accountID)
        if account == nil {
            Log.error(#file, "Account not found for ID: \(accountID)")
        }
    }

    var body: some View {
        if let account {
            List {
                Section(content: {
                    Button(action: { showDeleteAlert = true }, label: {
                        Text(DisplayStrings.deleteServerData)
                            .font(.system(.body))
                            .foregroundColor(.red)
                    })
                })
            }
            .listStyle(GroupedListStyle())
            .navigationTitle(DisplayStrings.advanced)
            .navigationBarTitleDisplayMode(.inline)
            .alert(DisplayStrings.deleteServerData, isPresented: $showDeleteAlert, actions: {
                Button(Strings.Generic.delete, role: .destructive, action: disableSync)
                Button(Strings.Generic.cancel, role: .cancel) {}
            }, message: {
                Text(Strings.AccountDetail.deleteServerDataMessage(libraryName: account.name))
            })
        } else {
            Text("Account unavailable")
                .foregroundColor(.secondary)
                .onAppear { dismiss() }
        }
    }

    private func disableSync() {
        account?.details?.syncPermissionGranted = false
        dismiss()
    }
}
