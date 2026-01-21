//
//  TPPKeychainStoredVariable.swift
//  The Palace Project
//
//  Created by Jacek Szyja on 22/05/2020.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

protocol Keyable {
  var key: String { get set }
}

class TPPKeychainVariable<VariableType>: Keyable {
  var key: String {
    didSet {
      guard key != oldValue else { return }

      alreadyInited = false
    }
  }

  fileprivate let transaction: TPPKeychainVariableTransaction

  fileprivate var alreadyInited = false

  fileprivate var cachedValue: VariableType?

  init(key: String, accountInfoQueue: DispatchQueue) {
    self.key = key
    self.transaction = TPPKeychainVariableTransaction(accountInfoQueue: accountInfoQueue)
  }

  func read() -> VariableType? {
    transaction.perform {
      // If currently cached value is valid, return from cache
      guard !alreadyInited else { return }

      // Otherwise, obtain the latest value from keychain
      cachedValue = TPPKeychain.shared()?.object(forKey: key) as? VariableType

      // set a flag indicating that current cache is good to use
      alreadyInited = true
    }

    // return cached value
    return cachedValue
  }

  func write(_ newValue: VariableType?) {
    transaction.perform {
      cachedValue = newValue
      alreadyInited = true
      
      // Write to keychain synchronously to ensure persistence
      if let newValue = newValue {
        TPPKeychain.shared()?.setObject(newValue, forKey: key)
      } else {
        TPPKeychain.shared()?.removeObject(forKey: key)
      }
    }
  }
}

class TPPKeychainCodableVariable<VariableType: Codable>: TPPKeychainVariable<VariableType> {
  override func read() -> VariableType? {
    transaction.perform {
      guard !alreadyInited else {
        Log.debug(#file, "🔐 [KEYCHAIN-READ] Using cached value for key: \(key)")
        return
      }
      
      Log.info(#file, "🔐 [KEYCHAIN-READ] Reading codable value for key: \(key)")
      Log.info(#file, "🔐 [KEYCHAIN-READ]   Value type: \(VariableType.self)")
      
      // Try new format first (direct JSON), then fall back to old format (NSKeyedArchiver-wrapped)
      if let jsonData = readJSONDataDirectly(forKey: key) {
        Log.info(#file, "🔐 [KEYCHAIN-READ]   Found JSON data: \(jsonData.count) bytes")
        do {
          cachedValue = try JSONDecoder().decode(VariableType.self, from: jsonData)
          alreadyInited = true
          Log.info(#file, "🔐 [KEYCHAIN-READ] ✅ Successfully decoded value for key: \(key)")
          return
        } catch {
          Log.error(#file, "🔐 [KEYCHAIN-READ] ❌ Failed to decode JSON keychain data for key \(key): \(error)")
        }
      } else {
        Log.info(#file, "🔐 [KEYCHAIN-READ]   No JSON data found directly")
      }
      
      // Fallback: try reading via old NSKeyedArchiver method for backward compatibility
      if let legacyData = TPPKeychain.shared()?.object(forKey: key) as? Data {
        Log.info(#file, "🔐 [KEYCHAIN-READ]   Found legacy data: \(legacyData.count) bytes")
        do {
          Log.info(#file, "🔐 [KEYCHAIN-READ]   Attempting to decode legacy NSKeyedArchiver data")
          cachedValue = try JSONDecoder().decode(VariableType.self, from: legacyData)
          alreadyInited = true
          
          // Migrate to new format
          Log.info(#file, "🔐 [KEYCHAIN-READ] ✅ Successfully decoded legacy data, migrating to new format")
          writeJSONDataDirectly(legacyData, forKey: key)
          return
        } catch {
          Log.error(#file, "🔐 [KEYCHAIN-READ] ❌ Failed to decode legacy keychain data for key \(key): \(error)")
        }
      } else {
        Log.info(#file, "🔐 [KEYCHAIN-READ]   No legacy data found")
      }
      
      Log.info(#file, "🔐 [KEYCHAIN-READ]   No value found for key: \(key)")
      cachedValue = nil
      alreadyInited = true
    }
    return cachedValue
  }

  override func write(_ newValue: VariableType?) {
    transaction.perform {
      cachedValue = newValue
      alreadyInited = true
      
      // Write to keychain synchronously to ensure persistence before app termination
      // For Codable types, write JSON directly without NSKeyedArchiver wrapper
      Log.info(#file, "🔐 [KEYCHAIN-WRITE] Writing codable value for key: \(key)")
      Log.info(#file, "🔐 [KEYCHAIN-WRITE]   Value type: \(VariableType.self)")
      Log.info(#file, "🔐 [KEYCHAIN-WRITE]   Value is nil: \(newValue == nil)")
      
      if let newValue = newValue {
        do {
          let jsonData = try JSONEncoder().encode(newValue)
          Log.info(#file, "🔐 [KEYCHAIN-WRITE]   Encoded JSON size: \(jsonData.count) bytes")
          writeJSONDataDirectly(jsonData, forKey: key)
        } catch {
          Log.error(#file, "🔐 [KEYCHAIN-WRITE] ❌ Failed to encode value for key \(key): \(error)")
          removeAllFormats(forKey: key)
        }
      } else {
        Log.info(#file, "🔐 [KEYCHAIN-WRITE]   Removing key (value is nil)")
        removeAllFormats(forKey: key)
      }
    }
  }
  
  /// Write JSON data directly to keychain without NSKeyedArchiver wrapper
  private func writeJSONDataDirectly(_ data: Data, forKey key: String) {
    // Use the key string directly for kSecAttrAccount (it expects a String, not Data)
    // Previous code used NSKeyedArchiver.archivedData which was inconsistent across app launches
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: key,  // Use string directly - this is what kSecAttrAccount expects
      kSecAttrService as String: "org.thepalaceproject.palace.keychain"  // Add service identifier for uniqueness
    ]
    
    // Check if item exists with new format
    var itemExists = false
    var resultRef: CFTypeRef?
    let existsStatus = SecItemCopyMatching(query as CFDictionary, &resultRef)
    if existsStatus == errSecSuccess {
      itemExists = true
    }
    
    // Also check for legacy formats and migrate if found
    if !itemExists {
      // Try legacy NSKeyedArchiver format
      let legacyKeyData = NSKeyedArchiver.archivedData(withRootObject: key)
      var legacyQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrAccount as String: legacyKeyData,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecReturnData as String: true
      ]
      var legacyRef: CFTypeRef?
      if SecItemCopyMatching(legacyQuery as CFDictionary, &legacyRef) == errSecSuccess {
        Log.info(#file, "🔐 [KEYCHAIN-WRITE] Migrating from legacy NSKeyedArchiver format for \(key)")
        SecItemDelete(legacyQuery as CFDictionary)
      }
      
      // Try legacy Data(utf8) format (previous fix attempt)
      legacyQuery[kSecAttrAccount as String] = Data(key.utf8)
      if SecItemCopyMatching(legacyQuery as CFDictionary, &legacyRef) == errSecSuccess {
        Log.info(#file, "🔐 [KEYCHAIN-WRITE] Migrating from legacy Data(utf8) format for \(key)")
        SecItemDelete(legacyQuery as CFDictionary)
      }
    }
    
    Log.info(#file, "🔐 [KEYCHAIN-WRITE]   Item exists: \(itemExists) (status: \(existsStatus))")
    
    if itemExists {
      // Update existing
      let update: [String: Any] = [
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
      ]
      let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
      if status == errSecSuccess {
        Log.info(#file, "🔐 [KEYCHAIN-WRITE] ✅ Updated existing keychain item for \(key)")
      } else {
        Log.error(#file, "🔐 [KEYCHAIN-WRITE] ❌ Failed to update keychain item for \(key): OSStatus \(status) (\(securityErrorMessage(status)))")
      }
    } else {
      // Add new
      var newItem = query
      newItem[kSecValueData as String] = data
      newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      let status = SecItemAdd(newItem as CFDictionary, nil)
      if status == errSecSuccess {
        Log.info(#file, "🔐 [KEYCHAIN-WRITE] ✅ Added new keychain item for \(key)")
      } else {
        Log.error(#file, "🔐 [KEYCHAIN-WRITE] ❌ Failed to add keychain item for \(key): OSStatus \(status) (\(securityErrorMessage(status)))")
      }
    }
  }
  
  /// Converts OSStatus to human-readable error message
  private func securityErrorMessage(_ status: OSStatus) -> String {
    switch status {
    case errSecSuccess: return "Success"
    case errSecDuplicateItem: return "Duplicate item"
    case errSecItemNotFound: return "Item not found"
    case errSecAuthFailed: return "Authentication failed"
    case errSecParam: return "Invalid parameter"
    case errSecAllocate: return "Allocation failure"
    case errSecNotAvailable: return "Not available"
    case errSecDecode: return "Decode failure"
    case errSecInteractionNotAllowed: return "Interaction not allowed"
    case -34018: return "Missing entitlement (keychain-access-groups)"
    default: return "Unknown error"
    }
  }
  
  /// Remove keychain items in all formats (new and legacy)
  private func removeAllFormats(forKey key: String) {
    // Remove new format
    let newQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: key,
      kSecAttrService as String: "org.thepalaceproject.palace.keychain"
    ]
    SecItemDelete(newQuery as CFDictionary)
    
    // Remove legacy formats
    TPPKeychain.shared()?.removeObject(forKey: key)
    
    // Remove legacy NSKeyedArchiver format
    let legacyKeyData = NSKeyedArchiver.archivedData(withRootObject: key)
    let legacyQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: legacyKeyData
    ]
    SecItemDelete(legacyQuery as CFDictionary)
    
    // Remove legacy Data(utf8) format
    let utf8Query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: Data(key.utf8)
    ]
    SecItemDelete(utf8Query as CFDictionary)
    
    Log.info(#file, "🔐 [KEYCHAIN-REMOVE] Removed all formats for key: \(key)")
  }
  
  /// Save data with the new stable string key format (used for migration)
  private func saveWithNewFormat(_ data: Data, forKey key: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: key,  // Use string directly
      kSecAttrService as String: "org.thepalaceproject.palace.keychain"  // Add service identifier
    ]
    
    // Delete any existing item with new format first
    SecItemDelete(query as CFDictionary)
    
    // Add with new format
    var newItem = query
    newItem[kSecValueData as String] = data
    newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    let status = SecItemAdd(newItem as CFDictionary, nil)
    
    if status == errSecSuccess {
      Log.info(#file, "🔐 [KEYCHAIN-MIGRATE] ✅ Migrated item to new format for \(key)")
    } else {
      Log.error(#file, "🔐 [KEYCHAIN-MIGRATE] ❌ Failed to migrate item for \(key): OSStatus \(status)")
    }
  }
  
  /// Read JSON data directly from keychain, migrating from old NSKeyedArchiver format if needed
  private func readJSONDataDirectly(forKey key: String) -> Data? {
    // Use the key string directly for kSecAttrAccount (matching writeJSONDataDirectly)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: key,  // Use string directly
      kSecAttrService as String: "org.thepalaceproject.palace.keychain",  // Match service identifier
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecReturnData as String: true
    ]
    
    var resultRef: CFTypeRef?
    var status = SecItemCopyMatching(query as CFDictionary, &resultRef)
    
    // If not found with new format, try legacy formats and migrate
    if status == errSecItemNotFound {
      Log.info(#file, "🔐 [KEYCHAIN-READ] Item not found with string key, trying legacy formats...")
      
      // Try 1: Legacy NSKeyedArchiver format
      let legacyKeyData = NSKeyedArchiver.archivedData(withRootObject: key)
      var legacyQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrAccount as String: legacyKeyData,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecReturnData as String: true
      ]
      status = SecItemCopyMatching(legacyQuery as CFDictionary, &resultRef)
      
      if status == errSecSuccess, let data = resultRef as? Data {
        Log.info(#file, "🔐 [KEYCHAIN-READ] Found legacy NSKeyedArchiver item, migrating...")
        saveWithNewFormat(data, forKey: key)
        SecItemDelete(legacyQuery as CFDictionary)
        return data
      }
      
      // Try 2: Legacy Data(utf8) format (previous fix attempt)
      legacyQuery[kSecAttrAccount as String] = Data(key.utf8)
      status = SecItemCopyMatching(legacyQuery as CFDictionary, &resultRef)
      
      if status == errSecSuccess, let data = resultRef as? Data {
        Log.info(#file, "🔐 [KEYCHAIN-READ] Found legacy Data(utf8) item, migrating...")
        saveWithNewFormat(data, forKey: key)
        SecItemDelete(legacyQuery as CFDictionary)
        return data
      }
      
      // Try 3: Plain string key without service (old TPPKeychain format)
      legacyQuery[kSecAttrAccount as String] = key
      legacyQuery.removeValue(forKey: kSecAttrService as String)
      status = SecItemCopyMatching(legacyQuery as CFDictionary, &resultRef)
      
      if status == errSecSuccess, let data = resultRef as? Data {
        Log.info(#file, "🔐 [KEYCHAIN-READ] Found item with plain string key (no service), migrating...")
        saveWithNewFormat(data, forKey: key)
        SecItemDelete(legacyQuery as CFDictionary)
        return data
      }
      
      Log.info(#file, "🔐 [KEYCHAIN-READ] No legacy format found either")
    }
    
    guard status == errSecSuccess, let data = resultRef as? Data else {
      return nil
    }
    
    // Check if this is old NSKeyedArchiver-wrapped data (binary plist)
    // Binary plists start with "bplist" magic bytes
    if data.count > 6, data[0] == 0x62 && data[1] == 0x70 { // "bp" in ASCII
      Log.info(#file, "Migrating legacy NSKeyedArchiver data for key: \(key)")
      // Try to unwrap using NSKeyedUnarchiver to get the JSON data
      if let unwrappedData = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSData.self, from: data) as? Data {
        Log.info(#file, "  Successfully unwrapped legacy data, re-saving in new format")
        // Re-save in new format (direct JSON)
        writeJSONDataDirectly(unwrappedData, forKey: key)
        return unwrappedData
      } else {
        Log.error(#file, "  Failed to unwrap legacy NSKeyedArchiver data")
        return nil
      }
    }
    
    // Modern format - return directly
    return data
  }
}

class TPPKeychainVariableTransaction {
  fileprivate let accountInfoQueue: DispatchQueue
  private let queueKey = DispatchSpecificKey<Void>()

  init(accountInfoQueue: DispatchQueue) {
    self.accountInfoQueue = accountInfoQueue
    self.accountInfoQueue.setSpecific(key: queueKey, value: ())
  }

  func perform(tasks: () -> Void) {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      tasks()
    } else {
      accountInfoQueue.sync {
        tasks()
      }
    }
  }
}
