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
      // Critical for credentials, auth tokens, cookies that must survive app termination
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
      guard !alreadyInited else { return }
      
      // Try new format first (direct JSON), then fall back to old format (NSKeyedArchiver-wrapped)
      if let jsonData = readJSONDataDirectly(forKey: key) {
        do {
          cachedValue = try JSONDecoder().decode(VariableType.self, from: jsonData)
          alreadyInited = true
          return
        } catch {
          Log.error(#file, "Failed to decode JSON keychain data for key \(key): \(error)")
        }
      }
      
      // Fallback: try reading via old NSKeyedArchiver method for backward compatibility
      if let legacyData = TPPKeychain.shared()?.object(forKey: key) as? Data {
        do {
          Log.info(#file, "Attempting to decode legacy NSKeyedArchiver data for key: \(key)")
          cachedValue = try JSONDecoder().decode(VariableType.self, from: legacyData)
          alreadyInited = true
          
          // Migrate to new format
          Log.info(#file, "  Successfully decoded legacy data, migrating to new format")
          writeJSONDataDirectly(legacyData, forKey: key)
          return
        } catch {
          Log.error(#file, "Failed to decode legacy keychain data for key \(key): \(error)")
        }
      }
      
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
      Log.debug(#file, "Writing `\(String(describing: newValue))` on keychain for \(key)")
      if let newValue = newValue {
        do {
          let jsonData = try JSONEncoder().encode(newValue)
          writeJSONDataDirectly(jsonData, forKey: key)
        } catch {
          Log.error(#file, "Failed to encode value for keychain key \(key): \(error)")
          TPPKeychain.shared()?.removeObject(forKey: key)
        }
      } else {
        TPPKeychain.shared()?.removeObject(forKey: key)
      }
    }
  }
  
  /// Write JSON data directly to keychain without NSKeyedArchiver wrapper
  private func writeJSONDataDirectly(_ data: Data, forKey key: String) {
    let keyData = NSKeyedArchiver.archivedData(withRootObject: key)
    
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: keyData
    ]
    
    // Check if item exists
    var itemExists = false
    var resultRef: CFTypeRef?
    if SecItemCopyMatching(query as CFDictionary, &resultRef) == errSecSuccess {
      itemExists = true
    }
    
    if itemExists {
      // Update existing
      let update: [String: Any] = [
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
      ]
      let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
      if status != errSecSuccess {
        Log.error(#file, "Failed to update keychain item for \(key): \(status)")
      }
    } else {
      // Add new
      var newItem = query
      newItem[kSecValueData as String] = data
      newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      let status = SecItemAdd(newItem as CFDictionary, nil)
      if status != errSecSuccess {
        Log.error(#file, "Failed to add keychain item for \(key): \(status)")
      }
    }
  }
  
  /// Read JSON data directly from keychain, migrating from old NSKeyedArchiver format if needed
  private func readJSONDataDirectly(forKey key: String) -> Data? {
    let keyData = NSKeyedArchiver.archivedData(withRootObject: key)
    
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: keyData,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecReturnData as String: true
    ]
    
    var resultRef: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &resultRef)
    
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
