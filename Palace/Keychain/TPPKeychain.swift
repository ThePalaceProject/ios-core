import Foundation
import Security

/// This class is capable of working with values serializable by NSKeyedArchiver.
@objc class TPPKeychain: NSObject {

  @objc static let sharedKeychain: TPPKeychain = {
    let keychain = TPPKeychain()
    return keychain
  }()

  private override init() {
    super.init()
  }

  private func defaultDictionary() -> NSMutableDictionary {
    let dictionary = NSMutableDictionary()
    dictionary[kSecClass] = kSecClassGenericPassword
    return dictionary
  }

  @objc func object(forKey key: String) -> Any? {
    guard let keyData = try? NSKeyedArchiver.archivedData(withRootObject: key, requiringSecureCoding: false) else {
      return nil
    }

    let dictionary = defaultDictionary()
    dictionary[kSecAttrAccount] = keyData
    dictionary[kSecMatchLimit] = kSecMatchLimitOne
    dictionary[kSecReturnData] = kCFBooleanTrue

    var resultRef: CFTypeRef?
    SecItemCopyMatching(dictionary, &resultRef)

    guard let resultData = resultRef as? Data else { return nil }

    return try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(resultData)
  }

  @objc func setObject(_ value: Any, forKey key: String) {
    guard let keyData = try? NSKeyedArchiver.archivedData(withRootObject: key, requiringSecureCoding: false),
          let valueData = try? NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: false) else {
      return
    }

    let queryDictionary = defaultDictionary()
    queryDictionary[kSecAttrAccount] = keyData

    if object(forKey: key) != nil {
      let updateDictionary = NSMutableDictionary()
      updateDictionary[kSecValueData] = valueData
      updateDictionary[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
      let status = SecItemUpdate(queryDictionary, updateDictionary)
      if status != noErr {
        Log.log("Failed to UPDATE secure values to keychain. This is a known issue when running from the debugger. Error: \(status)")
      }
    } else {
      let newItemDictionary = queryDictionary.mutableCopy() as! NSMutableDictionary
      newItemDictionary[kSecValueData] = valueData
      newItemDictionary[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
      let status = SecItemAdd(newItemDictionary, nil)
      if status != noErr {
        Log.log("Failed to ADD secure values to keychain. This is a known issue when running from the debugger. Error: \(status)")
      }
    }
  }

  @objc func removeObject(forKey key: String) {
    guard let keyData = try? NSKeyedArchiver.archivedData(withRootObject: key, requiringSecureCoding: false) else {
      return
    }

    let dictionary = defaultDictionary()
    dictionary[kSecAttrAccount] = keyData

    let status = SecItemDelete(dictionary)
    if status != noErr && status != errSecItemNotFound {
      Log.log("Failed to REMOVE object from keychain. error: \(status)")
    }
  }
}
