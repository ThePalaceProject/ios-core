import Foundation
import PalacePreferences
import PalaceAudiobookToolkit
import PalaceLogging
import PalaceKeychain

@objcMembers final class TPPKeychainManager: NSObject {

    // MARK: - Safe archive decoding
    //
    // `NSKeyedUnarchiver.unarchiveObject(with:)` signals a corrupt archive by
    // RAISING an ObjC exception, which Swift cannot catch — `try?` does not
    // help and the process aborts. Measured by bit-flipping each byte of a
    // valid archive in turn: the raising call aborts on 2 of 156 flips for an
    // archived String and 63 of 277 for an archived dictionary; the throwing
    // APIs below abort on none.
    //
    // That matters more here than almost anywhere else in the app.
    // `validateKeychain()` runs from `TPPAppDelegate.performBackgroundStartupTasks()`
    // on EVERY launch, and reaches both decoders below. A single corrupt
    // keychain item would therefore crash the app during startup, every time —
    // a loop a patron can only escape by reinstalling, which costs them their
    // downloaded books. Returning nil instead lets the item be skipped.

    /// Decodes an archived keychain KEY. Keys are always archived `String`s, so
    /// the class list is closed.
    static func decodeKeychainKey(_ data: Data) -> String? {
        (try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSString.self],
                                                 from: data)) as? String
    }

    /// Decodes an archived keychain VALUE.
    ///
    /// Deliberately untyped: `TPPKeychain` archives whatever callers store, and
    /// `TPPKeychainStoredVariable` has additionally written raw JSON for
    /// `Codable` types since the format change — so this cannot assume a class
    /// list without silently dropping values it should migrate. Uses the
    /// throwing top-level API, which is what `TPPKeychain.read` already uses
    /// for the same reason.
    static func decodeKeychainValue(_ data: Data) -> AnyObject? {
        (try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data)) as AnyObject?
    }

    private static let secClassItems: [String] = [
        kSecClassGenericPassword as String,
        kSecClassInternetPassword as String,
        kSecClassCertificate as String,
        kSecClassKey as String,
        kSecClassIdentity as String
    ]

    static func validateKeychain(settings: TPPSettings = AppContainer.production().settings) {
        if settings.appVersion == nil {
            Log.info(#file, "Fresh install detected. Cleaning up all keychain items...")
            cleanupAllKeychainItems()
        }

        if settings.appVersion != nil {
            updateKeychainForBackgroundFetch()
            manageFeedbooksData()
            manageFeedbookDrmPrivateKey()
        }
    }

    // Clean up all keychain items
    private static func cleanupAllKeychainItems() {
        Log.info(#file, "Starting keychain cleanup...")

        // First, try to get all items to log what we're cleaning up
        for secClass in secClassItems {
            let query: [String: AnyObject] = [
                kSecClass as String: secClass as AnyObject,
                kSecReturnData as String: kCFBooleanTrue,
                kSecReturnAttributes as String: kCFBooleanTrue,
                kSecReturnRef as String: kCFBooleanTrue,
                kSecMatchLimit as String: kSecMatchLimitAll
            ]

            var result: AnyObject?
            let status = withUnsafeMutablePointer(to: &result) {
                SecItemCopyMatching(query as CFDictionary, UnsafeMutablePointer($0))
            }

            if status == errSecSuccess {
                if let array = result as? [[String: Any]] {
                    for item in array {
                        if let keyData = item[kSecAttrAccount as String] as? Data,
                           let keyString = decodeKeychainKey(keyData) {
                            Log.info(#file, "Found keychain item to clean up: \(keyString)")
                        }
                    }
                }
            }
        }

        // Now perform the actual cleanup
        for secClass in secClassItems {
            let query: [String: Any] = [
                kSecClass as String: secClass
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                Log.error(#file, "Error deleting keychain items for class \(secClass): \(status)")
            }
        }

        // Additional cleanup for specific known items
        let knownKeys = [
            "barcode",
            "pin",
            "authToken",
            "adobeToken",
            "patron",
            "adobeVendor",
            "provider",
            "userID",
            "deviceID",
            "credentials",
            "authDefinition",
            "cookies",
            "authorizationIdentifier",
            // Add library-specific keys
            "TPPAccountAuthorization",
            "TPPAccountBarcode",
            "TPPAccountPIN",
            "TPPAccountAdobeTokenKey",
            "TPPAccountLicensorKey",
            "TPPAccountPatronKey",
            "TPPAccountAuthTokenKey",
            "TPPAccountAdobeVendorKey",
            "TPPAccountProviderKey",
            "TPPAccountUserIDKey",
            "TPPAccountDeviceIDKey",
            "TPPAccountCredentialsKey",
            "TPPAccountAuthDefinitionKey",
            "TPPAccountAuthCookiesKey"
        ]

        for key in knownKeys {
            TPPKeychain.shared.removeObject(forKey: key)
        }

        // Also clean up any library-specific keys
        for libraryUUID in AccountsManager.TPPAccountUUIDs {
            for key in knownKeys {
                let libraryKey = "\(key)_\(libraryUUID)"
                TPPKeychain.shared.removeObject(forKey: libraryKey)
            }
        }

        Log.info(#file, "Keychain cleanup completed")
    }

    /// Credentials need to be accessed while the phone is locked during a
    /// background fetch, so those keychain items need their default accessible
    /// level lowered one notch, if not already, to allow access any time after
    /// the first unlock per phone reboot.
    static func updateKeychainForBackgroundFetch() {
        let query: [String: AnyObject] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,  // old default
            kSecReturnData as String: kCFBooleanTrue,
            kSecReturnAttributes as String: kCFBooleanTrue,
            kSecReturnRef as String: kCFBooleanTrue,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: AnyObject?
        let lastResultCode = withUnsafeMutablePointer(to: &result) {
            SecItemCopyMatching(query as CFDictionary, UnsafeMutablePointer($0))
        }

        var values = [String: AnyObject]()
        if lastResultCode == noErr {
            guard let array = result as? [[String: Any]] else { return }
            for item in array {
                if let keyData = item[kSecAttrAccount as String] as? Data,
                   let valueData = item[kSecValueData as String] as? Data,
                   let keyString = decodeKeychainKey(keyData),
                   // A value that will not decode SKIPS the whole item rather
                   // than migrating it. That is deliberate and is the safe
                   // direction: the previous code decoded such an item to
                   // NSNull and wrote that back over it, destroying whatever
                   // was there. Not directly testable — this path needs a real
                   // `SecItemCopyMatching` against the device keychain — so it
                   // is documented rather than worked around; the decoders
                   // themselves are pinned by unit tests.
                   let value = decodeKeychainValue(valueData) {
                    values[keyString] = value
                }
            }
        }

        for (key, value) in values {
            TPPKeychain.shared.removeObject(forKey: key)
            TPPKeychain.shared.setObject(value, forKey: key)
            Log.debug(#file, "Keychain item \"\(key)\" updated with new accessible security level...")
        }
    }

    // Load feedbooks profile secrets
    private static func manageFeedbooksData() {
        // Go through each vendor and add their data to keychain so audiobook component can access securely
        for vendor in AudioBookVendors.allCases {
            guard let feedbookKeys = TPPSecrets.feedbookKeys(forVendor: vendor),
                  let profile = TPPSecrets.feedbookInfo(forVendor: vendor)["profile"] else {
                Log.error(#file, "Could not load secrets for Feedbook vendor: \(vendor.rawValue)")
                continue
            }
            let keyData = Data(feedbookKeys.utf8)
            let tag = Data("feedbook_drm_profile_\(profile)".utf8)

            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                kSecValueData as String: keyData
            ]
            let status = SecItemAdd(addQuery as CFDictionary, nil)
            if status != errSecSuccess && status != errSecDuplicateItem {
                logKeychainError(forVendor: vendor.rawValue, status: status, message: "FeedbookKeyManagement Error:")
            }
        }
    }

    private static func manageFeedbookDrmPrivateKey() {
        // Request DRM certificates for all vendors
        for vendor in AudioBookVendors.allCases {
            vendor.updateDrmCertificate()
        }
    }

    static func logKeychainError(forVendor vendor: String, status: OSStatus, message: String) {
        // This is unexpected
        var errMsg = ""
        if #available(iOS 11.3, *) {
            errMsg = (SecCopyErrorMessageString(status, nil) as String?) ?? ""
        }
        if errMsg.isEmpty {
            switch status {
            case errSecUnimplemented:
                errMsg = "errSecUnimplemented"
            case errSecDiskFull:
                errMsg = "errSecDiskFull"
            case errSecIO:
                errMsg = "errSecIO"
            case errSecOpWr:
                errMsg = "errSecOpWr"
            case errSecParam:
                errMsg = "errSecParam"
            case errSecWrPerm:
                errMsg = "errSecWrPerm"
            case errSecAllocate:
                errMsg = "errSecAllocate"
            case errSecUserCanceled:
                errMsg = "errSecUserCanceled"
            case errSecBadReq:
                errMsg = "errSecBadReq"
            default:
                errMsg = "Unknown OSStatus: \(status)"
            }
        }

        TPPErrorLogger.logError(
            withCode: .keychainItemAddFail,
            summary: "Keychain error for vendor \(vendor)",
            metadata: [
                "OSStatus": status,
                "SecCopyErrorMessage from OSStatus": errMsg,
                "message": message
            ])
    }
}
