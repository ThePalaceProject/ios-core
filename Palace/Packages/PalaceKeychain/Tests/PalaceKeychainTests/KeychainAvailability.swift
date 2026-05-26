//
//  KeychainAvailability.swift
//  PalaceKeychainTests
//
//  Helper for tests that need a real, writable keychain.
//
//  On GitHub Actions iOS Simulator runners, the test host has no keychain
//  entitlement, so SecItemAdd / SecItemCopyMatching fail with -34018
//  (errSecMissingEntitlement). Tests that exercise the real keychain must
//  skip in that environment rather than fail.
//

import XCTest
@testable import PalaceKeychain

enum KeychainAvailability {
    /// Probes the keychain by writing and reading a unique sentinel value.
    /// Returns true only when both the write and the read-back succeed,
    /// which means the host has a usable keychain entitlement.
    static var isWritable: Bool {
        let probeKey = "TPPKeychainAvailabilityProbe_\(UUID().uuidString)"
        let probeValue = "probe"
        TPPKeychain.shared.setObject(probeValue, forKey: probeKey)
        defer { TPPKeychain.shared.removeObject(forKey: probeKey) }
        return (TPPKeychain.shared.object(forKey: probeKey) as? String) == probeValue
    }

    /// Throws XCTSkip when the keychain is unwritable. Call from setUp or
    /// the top of an individual test.
    static func skipIfUnavailable() throws {
        guard isWritable else {
            throw XCTSkip("Keychain unavailable on this host (errSecMissingEntitlement -34018). Likely a CI simulator without keychain entitlements.")
        }
    }
}
