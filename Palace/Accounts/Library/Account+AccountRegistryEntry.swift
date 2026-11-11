//
//  Account+AccountRegistryEntry.swift
//  Palace
//
//  Lets the app's `Account` be the entry type of the `PalaceAccounts`
//  registry store. `Account` already declares `uuid`, so the body is empty.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import PalaceAccounts

extension Account: AccountRegistryEntry {}
