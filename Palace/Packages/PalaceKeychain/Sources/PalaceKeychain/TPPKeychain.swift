import Foundation
import Security
import PalaceLogging

/// This class is capable of working with values serializable by NSKeyedArchiver.
///
/// `Sendable`: stateless (no stored mutable properties) — every method operates
/// on function-local dictionaries and the thread-safe `SecItem*` keychain APIs.
/// The shared singleton is therefore data-race-safe under Swift 6.
public final class TPPKeychain: Sendable {

  public static let sharedKeychain: TPPKeychain = {
    let keychain = TPPKeychain()
    return keychain
  }()

  public static var shared: TPPKeychain { sharedKeychain }

  private init() {}

  private func defaultDictionary() -> NSMutableDictionary {
    let dictionary = NSMutableDictionary()
    dictionary[kSecClass] = kSecClassGenericPassword
    return dictionary
  }

  public func object(forKey key: String) -> Any? {
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

  public func setObject(_ value: Any, forKey key: String) {
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
      guard let newItemDictionary = queryDictionary.mutableCopy() as? NSMutableDictionary else {
        Log.log("Failed to copy keychain query dictionary")
        return
      }
      newItemDictionary[kSecValueData] = valueData
      newItemDictionary[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
      let status = SecItemAdd(newItemDictionary, nil)
      if status != noErr {
        Log.log("Failed to ADD secure values to keychain. This is a known issue when running from the debugger. Error: \(status)")
      }
    }
  }

  public func removeObject(forKey key: String) {
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
