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

      // invalidate current cache if key changed
      alreadyInited = false
    }
  }

  fileprivate let transaction: TPPKeychainVariableTransaction

  // marks whether or not was the `cachedValue` initialized
  fileprivate var alreadyInited = false

  // stores the last variable that was written to the keychain, or read from it
  // The stored value will also be invalidated once the key changes
  fileprivate var cachedValue: VariableType?

  init(key: String, accountInfoLock: NSRecursiveLock) {
    self.key = key
    self.transaction = TPPKeychainVariableTransaction(accountInfoLock: accountInfoLock)
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
      // set new value to cache
      cachedValue = newValue

      // set a flag indicating that current cache is good to use
      alreadyInited = true

      // write new data to keychain in background
      DispatchQueue.global(qos: .userInitiated).async { [key] in
        if let newValue = newValue {
          // if there is a new value, set it
          TPPKeychain.shared()?.setObject(newValue, forKey: key)
        } else {
          // otherwise remove old value from keychain
          TPPKeychain.shared()?.removeObject(forKey: key)
        }
      }
    }
  }
}

class TPPKeychainCodableVariable<VariableType: Codable>: TPPKeychainVariable<VariableType> {
  override func read() -> VariableType? {
    transaction.perform {
      guard !alreadyInited else { return }
      guard let data = TPPKeychain.shared()?.object(forKey: key) as? Data else {
        cachedValue = nil;
        alreadyInited = true;
        return
      }
      cachedValue = try? JSONDecoder().decode(VariableType.self, from: data)
      alreadyInited = true
    }
    return cachedValue
  }

  override func write(_ newValue: VariableType?) {
    transaction.perform {
      cachedValue = newValue
      alreadyInited = true
      DispatchQueue.global(qos: .userInitiated).async { [key] in
        Log.debug(#file, "Writing `\(String(describing: newValue))` on keychain for \(key)")
        if let newValue = newValue, let data = try? JSONEncoder().encode(newValue) {
          TPPKeychain.shared()?.setObject(data, forKey: key)
        } else {
          TPPKeychain.shared()?.removeObject(forKey: key)
        }
      }
    }
  }
}

class TPPKeychainVariableTransaction {
  fileprivate let accountInfoLock: NSRecursiveLock

  init(accountInfoLock: NSRecursiveLock) {
    self.accountInfoLock = accountInfoLock
  }

  func perform(tasks: () -> Void) {
    accountInfoLock.lock()
    defer {
      accountInfoLock.unlock()
    }

    tasks()
  }
}
