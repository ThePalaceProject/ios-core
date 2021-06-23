//
//  TPPBookRegistryMock.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 10/14/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
@testable import Palace

class TPPBookRegistryMock: NSObject, NYPLBookRegistrySyncing, TPPBookRegistryProvider {
  var syncing = false
  var identifiersToRecords = [String: TPPBookRegistryRecord]()

  func reset(_ libraryAccountUUID: String) {
    syncing = false
  }

  func syncResettingCache(_ resetCache: Bool,
                          completionHandler: (([AnyHashable : Any]?) -> Void)?) {
    syncing = true
    DispatchQueue.global(qos: .background).async {
      self.syncing = false
      completionHandler?(nil)
    }
  }

  func save() {
  }
    
  func addBook(book: TPPBook,
               state: TPPBookState) {
    let dict = ["metadata": book.dictionaryRepresentation(), "state": state.stringValue()] as [String : AnyObject]
    self.identifiersToRecords[book.identifier] = TPPBookRegistryRecord(dictionary: dict)
  }
    
  func readiumBookmarks(forIdentifier identifier: String) -> [TPPReadiumBookmark] {
    guard let record = identifiersToRecords[identifier] else { return [TPPReadiumBookmark]() }
    return record.readiumBookmarks.sorted{ $0.progressWithinBook > $1.progressWithinBook }
  }
  
  func location(forIdentifier identifier: String) -> TPPBookLocation? {
    guard let record = identifiersToRecords[identifier] else { return nil }
    return record.location
  }
    
  func setLocation(_ location: TPPBookLocation?, forIdentifier identifier: String) {
  }

  func add(_ bookmark: TPPReadiumBookmark, forIdentifier identifier: String) {
    guard let record = identifiersToRecords[identifier] else { return }
    var bookmarks = [TPPReadiumBookmark]()
    bookmarks.append(contentsOf: record.readiumBookmarks)
    bookmarks.append(bookmark)
    identifiersToRecords[identifier] = record.withReadiumBookmarks(bookmarks)
  }

  func delete(_ bookmark: TPPReadiumBookmark, forIdentifier identifier: String) {
    guard let record = identifiersToRecords[identifier] else { return }
    let bookmarks = record.readiumBookmarks.filter { $0 != bookmark }
    identifiersToRecords[identifier] = record.withReadiumBookmarks(bookmarks)
  }
  
  func replace(_ oldBookmark: TPPReadiumBookmark, with newBookmark: TPPReadiumBookmark, forIdentifier identifier: String) {
    guard let record = identifiersToRecords[identifier] else { return }
    var bookmarks = record.readiumBookmarks.filter { $0 != oldBookmark }
    bookmarks.append(newBookmark)
    identifiersToRecords[identifier] = record.withReadiumBookmarks(bookmarks)
  }
}
