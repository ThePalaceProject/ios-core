//
//  TPPBookRegistryMock.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 10/14/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
@testable import Palace

class TPPBookRegistryMock: NSObject, TPPBookRegistrySyncing, TPPBookRegistryProvider {
  var isSyncing = false
  var registry = [String: TPPBookRegistryRecord]()

  func reset(_ libraryAccountUUID: String) {
    isSyncing = false
  }

  func sync() {
    isSyncing = true
    DispatchQueue.global(qos: .background).async {
      self.isSyncing = false
    }
  }

  func save() {
  }
    
  func addBook(book: TPPBook,
               state: TPPBookState) {
    let dict = ["metadata": book.dictionaryRepresentation(), "state": state.stringValue()] as [String : AnyObject]
    self.registry[book.identifier] = TPPBookRegistryRecord(record: dict)
  }
    
  func readiumBookmarks(forIdentifier identifier: String) -> [TPPReadiumBookmark] {
    registry[identifier]?.readiumBookmarks?
      .sorted { $0.progressWithinBook < $1.progressWithinBook } ?? []
  }
  
  func location(forIdentifier identifier: String) -> TPPBookLocation? {
    guard let record = registry[identifier] else { return nil }
    return record.location
  }
    
  func setLocation(_ location: TPPBookLocation?, forIdentifier identifier: String) {
  }

  func add(_ bookmark: TPPReadiumBookmark, forIdentifier identifier: String) {
    guard registry[identifier] != nil else {
      return
    }
    if registry[identifier]?.readiumBookmarks == nil {
      registry[identifier]?.readiumBookmarks = [TPPReadiumBookmark]()
    }
    registry[identifier]?.readiumBookmarks?.append(bookmark)
  }

  func delete(_ bookmark: TPPReadiumBookmark, forIdentifier identifier: String) {
    registry[identifier]?.readiumBookmarks?.removeAll { $0 == bookmark }
  }
  
  func replace(_ oldBookmark: TPPReadiumBookmark, with newBookmark: TPPReadiumBookmark, forIdentifier identifier: String) {
    registry[identifier]?.readiumBookmarks?.removeAll { $0 == oldBookmark }
    registry[identifier]?.readiumBookmarks?.append(newBookmark)
  }
}
