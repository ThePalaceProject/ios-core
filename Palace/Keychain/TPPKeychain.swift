import Foundation
import Security

/// Swift port of TPPKeychain. Works with values serializable by NSKeyedArchiver.
@objcMembers
final class TPPKeychainSwift: NSObject {

  static let shared = TPPKeychainSwift()

  private override init() {
    super.init()
  }

  // MARK: - Private

  private func defaultQuery() -> [CFString: Any] {
    [kSecClass: kSecClassGenericPassword]
  }

  // MARK: - Public API

  func object(forKey key: String) -> Any? {
    guard let keyData = try? NSKeyedArchiver.archivedData(
      withRootObject: key, requiringSecureCoding: false
    ) else { return nil }

    var query = defaultQuery()
    query[kSecAttrAccount] = keyData
    query[kSecMatchLimit] = kSecMatchLimitOne
    query[kSecReturnData] = kCFBooleanTrue

    var result: CFTypeRef?
    SecItemCopyMatching(query as CFDictionary, &result)

    guard let data = result as? Data else { return nil }
    return try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data)
  }

  func setObject(_ value: Any, forKey key: String) {
    guard let keyData = try? NSKeyedArchiver.archivedData(
      withRootObject: key, requiringSecureCoding: false
    ),
    let valueData = try? NSKeyedArchiver.archivedData(
      withRootObject: value, requiringSecureCoding: false
    ) else { return }

    var query = defaultQuery()
    query[kSecAttrAccount] = keyData

    if object(forKey: key) != nil {
      // Update existing item
      let updateDict: [CFString: Any] = [
        kSecValueData: valueData,
        kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
      ]
      let status = SecItemUpdate(query as CFDictionary, updateDict as CFDictionary)
      if status != noErr {
        Log.warn(#file, "Failed to UPDATE secure values to keychain. Error: \(status)")
      }
    } else {
      // Add new item
      var newItem = query
      newItem[kSecValueData] = valueData
      newItem[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
      let status = SecItemAdd(newItem as CFDictionary, nil)
      if status != noErr {
        Log.warn(#file, "Failed to ADD secure values to keychain. Error: \(status)")
      }
    }
  }

  func removeObject(forKey key: String) {
    guard let keyData = try? NSKeyedArchiver.archivedData(
      withRootObject: key, requiringSecureCoding: false
    ) else { return }

    var query = defaultQuery()
    query[kSecAttrAccount] = keyData

    let status = SecItemDelete(query as CFDictionary)
    if status != noErr && status != errSecItemNotFound {
      Log.warn(#file, "Failed to REMOVE object from keychain. Error: \(status)")
    }
  }
}
