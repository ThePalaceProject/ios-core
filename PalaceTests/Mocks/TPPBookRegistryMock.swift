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
  
  func genericBookmarksForIdentifier(_ bookIdentifier: String) -> [Palace.TPPBookLocation] {
    registry[bookIdentifier]?.genericBookmarks ?? []
  }
  
  func addOrReplaceGenericBookmark(_ location: Palace.TPPBookLocation, forIdentifier bookIdentifier: String) {
    guard let existingBookmark = registry[bookIdentifier]?.genericBookmarks?.first(where: { $0 == location }) else {
      addGenericBookmark(location, forIdentifier: bookIdentifier)
      return
    }

    replaceGenericBookmark(existingBookmark, with: location, forIdentifier: bookIdentifier)
  }
  
  func addGenericBookmark(_ location: Palace.TPPBookLocation, forIdentifier bookIdentifier: String) {
    guard registry[bookIdentifier] != nil else {
      return
    }

    if registry[bookIdentifier]?.genericBookmarks == nil {
      registry[bookIdentifier]?.genericBookmarks = [TPPBookLocation]()
    }
    registry[bookIdentifier]?.genericBookmarks?.append(location)
  }
  
  func deleteGenericBookmark(_ location: Palace.TPPBookLocation, forIdentifier bookIdentifier: String) {
    registry[bookIdentifier]?.genericBookmarks?.removeAll { $0.locationString == location.locationString }
  }
  
  func replaceGenericBookmark(_ oldLocation: Palace.TPPBookLocation, with newLocation: Palace.TPPBookLocation, forIdentifier: String) {
    deleteGenericBookmark(oldLocation, forIdentifier: forIdentifier)
    registry[forIdentifier]?.genericBookmarks?.append(newLocation)
  }
}

extension TPPBookRegistryMock {
  func preloadData(bookIdentifier: String, locations: [TPPBookLocation]) {
    locations.forEach { addGenericBookmark($0, forIdentifier: bookIdentifier) }
  }
}
