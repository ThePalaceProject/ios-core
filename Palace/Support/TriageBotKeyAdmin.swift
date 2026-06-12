//
//  TriageBotKeyAdmin.swift
//  Palace
//
//  Test-seam wrapper over AnthropicKeyStore for the Developer Settings
//  "Anthropic API Key" row. The pure logic (trim + empty-rejection + status)
//  is unit-tested via an injected AnthropicKeyStoring; the real Keychain is
//  not exercised in tests (errSecMissingEntitlement in the unit host).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import TriageBotIOS

/// Storage seam so the admin logic can be unit-tested without the real
/// Keychain. `AnthropicKeyStore` (the production implementation) conforms.
protocol AnthropicKeyStoring {
    func read() -> String?
    @discardableResult func write(_ key: String) -> Bool
    @discardableResult func delete() -> Bool
}

extension AnthropicKeyStore: AnthropicKeyStoring {}

/// Drives the Developer Settings "Anthropic API Key" row. Lets a TestFlight
/// tester load a key onto their own device's Keychain at runtime — so the
/// Triage Bot AI fallback can be exercised — without the token ever entering
/// source or the app binary. Production App Store users never reach the row
/// (engineering sections are hidden there), so their Keychain stays empty and
/// the fallback stays off.
struct TriageBotKeyAdmin {
    private let store: AnthropicKeyStoring

    init(store: AnthropicKeyStoring = AnthropicKeyStore()) {
        self.store = store
    }

    /// True when a non-empty key is currently stored.
    var hasStoredKey: Bool {
        guard let key = store.read() else { return false }
        return !key.isEmpty
    }

    /// Trims the pasted value and stores it only if non-empty. Returns `true`
    /// iff a key was written. An empty/whitespace-only paste is rejected and
    /// leaves any existing key untouched (so a fat-fingered empty save can't
    /// silently wipe a working key).
    @discardableResult
    func save(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return store.write(trimmed)
    }

    /// Removes the stored key. Returns `true` if a key was present.
    @discardableResult
    func clear() -> Bool {
        store.delete()
    }
}
