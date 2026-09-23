//
//  AudioBookVendors+Extensions.swift
//  The Palace Project
//
//  Created by Vladimir Fedorov on 03.09.2020.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
import PalaceAudiobookToolkit
import PalaceLogging

extension AudioBookVendors {

    /// Vendor tag
    private var tag: String {
        "\(FeedbookDRMPublicKeyTag)\(self.rawValue)"
    }

    /// UserDefaults key to store certificate date
    private var validThroughDateKey: String {
        "\(tag)_validThroughDate"
    }

    /// Update vendor's DRM key
    /// - Parameter completion: Completion
    func updateDrmCertificate(completion: ((_ error: Error?) -> Void)? = nil) {
        // F-011 class-of-bug guard
        switch self {
        case .cantook: updateCantookDRMCertificate(completion: completion)
        }
    }

    /// Update Cantook DRM public key
    ///
    /// If the key is saved and its saved expiration date is later than today, the function doesn't request a new public key.
    /// - Parameter completion: Completion
    private func updateCantookDRMCertificate(completion: ((_ error: Error?) -> Void)? = nil) {
        // Check if we have a valid key
        if let date = UserDefaults.standard.value(forKey: validThroughDateKey) as? Date, Date() < date {
            // we have a certificate with a valid date
            completion?(nil)
            return
        }

        // `DPLAAudiobooks.drmKey`'s completion is `@Sendable`, but the caller's
        // `completion` is a plain `((Error?) -> Void)?` (the public API can't
        // require `@Sendable` without rippling to every caller). Capturing that
        // bare optional closure inside the `@Sendable` callback trips
        // `sending 'completion' risks data races`. Box it once before entering
        // `drmKey` so the `@Sendable` closure captures the Sendable carrier.
        let completionBox = SendableCertCompletion(completion)
        // Fetch a new drmKey
        DPLAAudiobooks.drmKey { (data, date, error) in
            if let error = error {
                if error is DPLAAudiobooks.DPLAError {
                    Log.error(#file, "DPLA key-fetch error: \(error)")
                } else {
                    Log.error(#file, "Could not receive DRM public key, URL: \(DPLAAudiobooks.certificateUrl): \(error)")
                }
                completionBox.fire(error)
                return
            }
            // drmKey completion handler returns either non-empty data value or an error
            guard let keyData = data else {
                Log.error(#file, "Public key data is empty, URL: \(DPLAAudiobooks.certificateUrl)")
                completionBox.fire(DPLAAudiobooks.DPLAError.drmKeyError("Public key data is empty, URL: \(DPLAAudiobooks.certificateUrl)"))
                return
            }
            // Check if we have a valid date
            if let date = date {
                // Save this date to avoid fetching this certificate untill it becomes invalid
                UserDefaults.standard.set(date, forKey: self.validThroughDateKey)
            }

            // Save SecKey
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrApplicationTag as String: self.tag.data(using: .utf8) as Any,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                kSecValueData as String: keyData,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic
            ]

            // Clean up before adding a new key value
            SecItemDelete(addQuery as CFDictionary)
            let status = SecItemAdd(addQuery as CFDictionary, nil)
            if status != errSecSuccess && status != errSecDuplicateItem {
                TPPKeychainManager.logKeychainError(forVendor: self.rawValue, status: status, message: "FeedbookDrmPrivateKeyManagement Error:")
            }

            completionBox.fire(nil)
        }
    }

}

/// `Sendable` wrapper for the optional `(Error?) -> Void` completion of
/// `updateDrmCertificate`.
///
/// `DPLAAudiobooks.drmKey`'s completion is `@Sendable`, so the caller's plain
/// (non-`@Sendable`) optional completion cannot be captured inside it without a
/// `sending` diagnostic. This box lets the completion cross that boundary while
/// keeping the public `updateDrmCertificate` API free of a `@Sendable`
/// requirement that would ripple to callers. Mirrors `SendableDecryptCompletion`
/// (LCPAudiobooks).
///
/// - Sendable invariant: `fire(_:)` forwards to the wrapped closure. The
///   underlying `drmKey` contract invokes its completion exactly once, so
///   `fire(_:)` runs at most once per certificate update. The wrapped closure is
///   otherwise opaque, hence `@unchecked`.
private struct SendableCertCompletion: @unchecked Sendable {
    private let completion: ((Error?) -> Void)?

    init(_ completion: ((Error?) -> Void)?) {
        self.completion = completion
    }

    func fire(_ error: Error?) {
        completion?(error)
    }
}
