//
//  TPPBookRegistryRecord.swift
//  Palace
//
//  Created by Vladimir Fedorov on 09.11.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation


/// An element of `TPPBookRegistry`
@objcMembers
class TPPBookRegistryRecord: NSObject {
  var book: TPPBook
  var location: TPPBookLocation?
  var state: TPPBookState
  var fulfillmentId: String?
  var readiumBookmarks: [TPPReadiumBookmark]?
  var genericBookmarks: [TPPBookLocation]?
  
  init(book: TPPBook, location: TPPBookLocation? = nil, state: TPPBookState, fulfillmentId: String? = nil, readiumBookmarks: [TPPReadiumBookmark]? = nil, genericBookmarks: [TPPBookLocation]? = nil) {
    self.book = book
    self.location = location
    self.state = state
    self.fulfillmentId = fulfillmentId
    self.readiumBookmarks = readiumBookmarks
    self.genericBookmarks = genericBookmarks
  }
  
  init?(record: TPPBookRegistryData) {
    guard let bookObject = record.object(for: .book),
          let book = TPPBook(dictionary: bookObject),
          let stateString = record.value(for: .state) as? String,
          let state = TPPBookState(stateString)
            
    else {
      return nil
    }
    self.book = book
    self.state = state
    self.fulfillmentId = record.value(for: .fulfillmentId) as? String
    self.location = nil
  }
  
  var dictionaryRepresentation: [String: Any?] {
    var dictionary = TPPBookRegistryData()
    dictionary.setObject(book.dictionaryRepresentation(), for: .book)
    dictionary.setValue(state.stringValue(), for: .state)
    dictionary.setValue(fulfillmentId, for: .fulfillmentId)
    return dictionary as [String: Any?]
  }
}
