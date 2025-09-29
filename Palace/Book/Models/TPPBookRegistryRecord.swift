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

  init(
    book: TPPBook,
    location: TPPBookLocation? = nil,
    state: TPPBookState,
    fulfillmentId: String? = nil,
    readiumBookmarks: [TPPReadiumBookmark]? = [],
    genericBookmarks: [TPPBookLocation]? = []
  ) {
    self.book = book
    self.location = location
    self.state = state
    self.fulfillmentId = fulfillmentId
    self.readiumBookmarks = readiumBookmarks
    self.genericBookmarks = genericBookmarks

    super.init()

    if let defaultAcquisition = book.defaultAcquisition {
      defaultAcquisition.availability.matchUnavailable { _ in
      } limited: { _ in
      } unlimited: { _ in
      } reserved: { [weak self] _ in
        self?.state = .holding
      } ready: { [weak self] _ in
        self?.state = .holding
      }

    } else {
      // Since the book has no default acqusition, there is no reliable way to
      // determine if the book is on hold (although it may be), nor is there any
      // way to download the book if it is available. As such, we give the book a
      // special "unsupported" state which will allow other parts of the app to
      // ignore it as appropriate. Unsupported books should generally only appear
      // when a user has checked out or reserved a book in an unsupported format
      // using another app.
      self.state = .unsupported
    }
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
    fulfillmentId = record.value(for: .fulfillmentId) as? String
    if let location = record.object(for: .location) {
      self.location = TPPBookLocation(dictionary: location)
    }
    if let recordReadiumBookmarks = record.array(for: .readiumBookmarks) {
      readiumBookmarks = recordReadiumBookmarks.compactMap { TPPReadiumBookmark(dictionary: $0 as NSDictionary) }
    }
    if let recordGenericBookmarks = record.array(for: .genericBookmarks) {
      genericBookmarks = recordGenericBookmarks.compactMap { TPPBookLocation(dictionary: $0) }
    }
  }

  var dictionaryRepresentation: [String: Any] {
    var dictionary = TPPBookRegistryData()
    dictionary.setValue(book.dictionaryRepresentation(), for: .book)
    dictionary.setValue(state.stringValue(), for: .state)
    dictionary.setValue(fulfillmentId, for: .fulfillmentId)
    dictionary.setValue(location?.dictionaryRepresentation, for: .location)
    dictionary.setValue(
      readiumBookmarks?.compactMap { $0.dictionaryRepresentation as? [String: Any] },
      for: .readiumBookmarks
    )
    dictionary.setValue(genericBookmarks?.map(\.dictionaryRepresentation), for: .genericBookmarks)
    return dictionary
  }
}
