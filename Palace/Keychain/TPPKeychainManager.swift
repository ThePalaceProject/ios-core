import Foundation
import PalaceAudiobookToolkit

@objcMembers final class TPPKeychainManager: NSObject {

  private enum KeychainGroups: String {
    case groupKeychainID = "88CBA74T8K.org.thepalaceproject.palace.SharedKeychainGroup"
  }

  private static let secClassItems: [String] = [
    kSecClassGenericPassword as String,
    kSecClassInternetPassword as String,
    kSecClassCertificate as String,
    kSecClassKey as String,
    kSecClassIdentity as String
  ]

  private static let secAttrAccessGroups: [String] = [
    KeychainGroups.groupKeychainID.rawValue,
  ]

  class func validateKeychain() {
    removeItemsFromPreviousInstalls()
    updateKeychainForBackgroundFetch()
    manageFeedbooksData()
    manageFeedbookDrmPrivateKey()
  }

  // The app does not handle DRM Authentication logic when assuming a user
  // is already logged in when finding a username/pin stored in the keychain
  // from a previous app install.
  private class func removeItemsFromPreviousInstalls() {
    if (TPPSettings.shared.appVersion != nil) {
      return
    }
    Log.info(#file, "Fresh install detected. Purging any existing keychain items...")

    for accessGroup in secAttrAccessGroups {
      for secClass in secClassItems {
        let queryDelete: [String: Any] = [
          kSecClass as String : secClass,
          kSecAttrAccessGroup as String: accessGroup
        ]
        let resultCodeDelete = SecItemDelete(queryDelete as CFDictionary)
        if resultCodeDelete == noErr {
          Log.debug(#file, "\(secClass) item successfully purged from keychain group: \(accessGroup)")
        }
      }
    }
  }
  
  private class func getAllKeyChainItemsOfClass(_ secClass: String,
                                                group: KeychainGroups) -> [String:AnyObject] {

    let query: [String: AnyObject] = [
      kSecClass as String : secClass as AnyObject,
      kSecAttrAccessGroup as String : group as AnyObject,
      kSecReturnData as String  : kCFBooleanTrue,
      kSecReturnAttributes as String : kCFBooleanTrue,
      kSecReturnRef as String : kCFBooleanTrue,
      kSecMatchLimit as String : kSecMatchLimitAll
    ]

    var result: AnyObject?
    let lastResultCode = withUnsafeMutablePointer(to: &result) {
      SecItemCopyMatching(query as CFDictionary, UnsafeMutablePointer($0))
    }

    var values = [String:AnyObject]()
    if lastResultCode == noErr {
      guard let array = result as? Array<Dictionary<String, Any>> else { return values }
      for item in array {
        if let keyData = item[kSecAttrAccount as String] as? Data,
          let valueData = item[kSecValueData as String] as? Data,
          let keyString = NSKeyedUnarchiver.unarchiveObject(with: keyData) as? String {
            Log.debug(#file, "Value found for keychain key: \(keyString)")
            let value = NSKeyedUnarchiver.unarchiveObject(with: valueData) as AnyObject
            values[keyString] = value
        }
      }
    }
    return values
  }

  /// Credentials need to be accessed while the phone is locked during a
  /// background fetch, so those keychain items need their default accessible
  /// level lowered one notch, if not already, to allow access any time after
  /// the first unlock per phone reboot.
  class func updateKeychainForBackgroundFetch() {

    let query: [String: AnyObject] = [
      kSecClass as String : kSecClassGenericPassword,
      kSecAttrAccessible as String : kSecAttrAccessibleWhenUnlocked,  //old default
      kSecReturnData as String  : kCFBooleanTrue,
      kSecReturnAttributes as String : kCFBooleanTrue,
      kSecReturnRef as String : kCFBooleanTrue,
      kSecMatchLimit as String : kSecMatchLimitAll
    ]

    var result: AnyObject?
    let lastResultCode = withUnsafeMutablePointer(to: &result) {
      SecItemCopyMatching(query as CFDictionary, UnsafeMutablePointer($0))
    }

    var values = [String:AnyObject]()
    if lastResultCode == noErr {
      guard let array = result as? Array<Dictionary<String, Any>> else { return }
      for item in array {
        if let keyData = item[kSecAttrAccount as String] as? Data,
          let valueData = item[kSecValueData as String] as? Data,
          let keyString = NSKeyedUnarchiver.unarchiveObject(with: keyData) as? String {
          let value = NSKeyedUnarchiver.unarchiveObject(with: valueData) as AnyObject
          values[keyString] = value
        }
      }
    }

    for (key, value) in values {
      TPPKeychain.shared().removeObject(forKey: key)
      TPPKeychain.shared().setObject(value, forKey: key)
      Log.debug(#file, "Keychain item \"\(key)\" updated with new accessible security level...")
    }
  }
  
  // Load feedbooks profile secrets
  private class func manageFeedbooksData() {
    // Go through each vendor and add their data to keychain so audiobook component can access securely
    for vendor in AudioBookVendors.allCases {
      guard let keyData = TPPSecrets.feedbookKeys(forVendor: vendor)?.data(using: .utf8),
        let profile = TPPSecrets.feedbookInfo(forVendor: vendor)["profile"],
        let tag = "feedbook_drm_profile_\(profile)".data(using: .utf8) else {
          Log.error(#file, "Could not load secrets for Feedbook vendor: \(vendor.rawValue)")
          continue
      }
        
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
    
  private class func manageFeedbookDrmPrivateKey() {
    // Request DRM certificates for all vendors
    for vendor in AudioBookVendors.allCases {
      vendor.updateDrmCertificate()
    }
  }
    
  class func logKeychainError(forVendor vendor:String, status: OSStatus, message: String) {
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
        "message": message,
    ])
  }
}
