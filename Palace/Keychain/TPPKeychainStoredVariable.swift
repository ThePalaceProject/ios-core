//
//  TPPKeychainStoredVariable.swift
//  The Palace Project
//
//  Created by Jacek Szyja on 22/05/2020.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

// MARK: - Keyable

protocol Keyable {
  var key: String { get set }
}

// MARK: - TPPKeychainVariable

class TPPKeychainVariable<VariableType>: Keyable {
  var key: String {
    didSet {
      guard key != oldValue else {
        return
      }

      alreadyInited = false
    }
  }

  fileprivate let transaction: TPPKeychainVariableTransaction

  fileprivate var alreadyInited = false

  fileprivate var cachedValue: VariableType?

  init(key: String, accountInfoQueue: DispatchQueue) {
    self.key = key
    transaction = TPPKeychainVariableTransaction(accountInfoQueue: accountInfoQueue)
  }

  func read() -> VariableType? {
    transaction.perform {
      // If currently cached value is valid, return from cache
      guard !alreadyInited else {
        return
      }

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

      DispatchQueue.global(qos: .userInitiated).async { [key] in
        if let newValue = newValue {
          TPPKeychain.shared()?.setObject(newValue, forKey: key)
        } else {
          TPPKeychain.shared()?.removeObject(forKey: key)
        }
      }
    }
  }
}

// MARK: - TPPKeychainCodableVariable

class TPPKeychainCodableVariable<VariableType: Codable>: TPPKeychainVariable<VariableType> {
  override func read() -> VariableType? {
    transaction.perform {
      guard !alreadyInited else {
        return
      }
      guard let data = TPPKeychain.shared()?.object(forKey: key) as? Data else {
        cachedValue = nil
        alreadyInited = true
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

// MARK: - TPPKeychainVariableTransaction

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
