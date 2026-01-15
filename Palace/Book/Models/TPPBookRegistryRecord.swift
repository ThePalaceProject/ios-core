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
  
  /// Creates a registry record with the specified state.
  /// 
  /// **Important:** This initializer preserves the passed `state` value. If you need to derive
  /// the initial state from book availability, use `TPPBookRegistryRecord.deriveInitialState(for:)` first.
  ///
  /// - Parameters:
  ///   - book: The book metadata
  ///   - location: Reading position (optional)
  ///   - state: The book state - this value is preserved as-is
  ///   - fulfillmentId: DRM fulfillment identifier (optional)
  ///   - readiumBookmarks: Readium-format bookmarks
  ///   - genericBookmarks: Generic location bookmarks
  init(book: TPPBook, location: TPPBookLocation? = nil, state: TPPBookState, fulfillmentId: String? = nil, readiumBookmarks: [TPPReadiumBookmark]? = [], genericBookmarks: [TPPBookLocation]? = []) {
    self.book = book
    self.location = location
    self.fulfillmentId = fulfillmentId
    self.readiumBookmarks = readiumBookmarks
    self.genericBookmarks = genericBookmarks
    
    // Preserve the passed state - do NOT override based on availability
    // The caller is responsible for determining the correct state
    self.state = state

    super.init()
  }
  
  /// Derives the appropriate initial state for a newly borrowed/discovered book based on its availability.
  /// Use this when adding a book to the registry for the first time without a known state.
  ///
  /// - Parameter book: The book to derive state for
  /// - Returns: The appropriate initial state based on availability
  static func deriveInitialState(for book: TPPBook) -> TPPBookState {
    guard let defaultAcquisition = book.defaultAcquisition else {
      // No acquisition means unsupported format
      return .unsupported
    }
    
    var derivedState: TPPBookState = .downloadNeeded
    
    defaultAcquisition.availability.matchUnavailable { _ in
      derivedState = .downloadNeeded
    } limited: { _ in
      derivedState = .downloadNeeded
    } unlimited: { _ in
      derivedState = .downloadNeeded
    } reserved: { _ in
      derivedState = .holding
    } ready: { _ in
      derivedState = .holding
    }
    
    return derivedState
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
    if let location = record.object(for: .location) {
        self.location = TPPBookLocation(dictionary: location)
    }
    if let recordReadiumBookmarks = record.array(for: .readiumBookmarks) {
      self.readiumBookmarks = recordReadiumBookmarks.compactMap { TPPReadiumBookmark(dictionary: $0 as NSDictionary) }
    }
    if let recordGenericBookmarks = record.array(for: .genericBookmarks) {
      self.genericBookmarks = recordGenericBookmarks.compactMap { TPPBookLocation(dictionary: $0) }
    }
  }
  
  var dictionaryRepresentation: [String: Any] {
    var dictionary = TPPBookRegistryData()
    dictionary.setValue(book.dictionaryRepresentation(), for: .book)
    dictionary.setValue(state.stringValue(), for: .state)
    dictionary.setValue(fulfillmentId, for: .fulfillmentId)
    dictionary.setValue(self.location?.dictionaryRepresentation, for: .location)
    dictionary.setValue(readiumBookmarks?.compactMap { $0.dictionaryRepresentation as? [String: Any] }, for: .readiumBookmarks)
    dictionary.setValue(genericBookmarks?.map { $0.dictionaryRepresentation }, for: .genericBookmarks)
    return dictionary
  }
}
