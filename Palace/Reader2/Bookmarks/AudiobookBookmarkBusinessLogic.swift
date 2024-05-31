//
//  AudiobookBookmarkBusinessLogic.swift
//  Palace
//
//  Created by Maurice Carrier on 4/12/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import PalaceAudiobookToolkit

@objc public class AudiobookBookmarkBusinessLogic: NSObject {
  private var book: TPPBook
  private var registry: TPPBookRegistryProvider
  private var annotationsManager: AnnotationsManager
  private var isSyncing: Bool = false
  
  @objc convenience init(book: TPPBook) {
    self.init(book: book, registry: TPPBookRegistry.shared, annotationsManager: TPPAnnotationsWrapper())
  }
  
  init(book: TPPBook, registry: TPPBookRegistryProvider, annotationsManager: AnnotationsManager) {
    self.book = book
    self.registry = registry
    self.annotationsManager = annotationsManager
  }
  
  private func fetchLocalBookmarks() -> [AudioBookmark] {
    return registry.genericBookmarksForIdentifier(book.identifier).compactMap { bookmark in
      guard let dictionary = bookmark.locationStringDictionary(),
            let localBookmark = AudioBookmark.create(locatorData: dictionary) else {
        return nil
      }
      return localBookmark
    }
  }

  private func fetchServerBookmarks(completion: @escaping ([AudioBookmark]) -> Void) {
    annotationsManager.getServerBookmarks(forBook: book.identifier, atURL: self.book.annotationsURL, motivation: .bookmark) { serverBookmarks in
      guard let audioBookmarks = serverBookmarks as? [AudioBookmark] else {
        completion([])
        return
      }
      
      completion(audioBookmarks)
    }
  }
  
  private var completionHandlersQueue: [([AudioBookmark]) -> Void] = []

  func syncBookmarks(localBookmarks: [AudioBookmark], completion: (([AudioBookmark]) -> Void)? = nil) {
    guard !isSyncing else {
      if let completion {
        completionHandlersQueue.append(completion)
      }
      return
    }
    
    isSyncing = true
    Task {
      await uploadUnsyncedBookmarks(localBookmarks)
      
      fetchServerBookmarks { [weak self] remoteBookmarks in
        guard let strongSelf = self else { return }
        
        strongSelf.updateLocalBookmarks(with: remoteBookmarks) { updatedBookmarks in
          strongSelf.finalizeSync(with: updatedBookmarks, completion: completion)
        }
      }
    }
  }
  
  private func uploadUnsyncedBookmarks(_ localBookmarks: [AudioBookmark]) async {
    let unsyncedLocalBookmarks = localBookmarks.filter { $0.isUnsynced }
    
    for bookmark in unsyncedLocalBookmarks {
      do {
        try await uploadBookmark(bookmark)
      } catch {
        ATLog(.debug, "Failed to save annotation with error: \(error.localizedDescription)")
      }
    }
  }
  
  private func uploadBookmark(_ bookmark: AudioBookmark) async throws {
    guard let data = bookmark.toData(),
            let locationString = String(data: data, encoding: .utf8)
    else { return }

    guard let annotationId = try await annotationsManager.postAudiobookBookmark(forBook: self.book.identifier, selectorValue: locationString) else {
      return
    }
    
    replaceBookmarkInLocalStore(bookmark, withAnnotationId: annotationId)
  }
  
  private func replaceBookmarkInLocalStore(_ bookmark: AudioBookmark, withAnnotationId annotationId: String) {
    if let updatedBookmark = bookmark.copy() as? AudioBookmark {
      updatedBookmark.annotationId = annotationId
      replace(oldLocation: bookmark, with: updatedBookmark)
    }
  }

  private func updateLocalBookmarks(with remoteBookmarks: [AudioBookmark], completion: @escaping ([AudioBookmark]) -> Void) {
    var updatedLocalBookmarks = fetchLocalBookmarks()
    
    guard annotationsManager.syncIsPossibleAndPermitted else {
      completion(updatedLocalBookmarks)
      return
    }

    let existingLocalBookmarkIds = Set(updatedLocalBookmarks.compactMap { $0.annotationId })
    let newRemoteBookmarks = remoteBookmarks.filter { remoteBookmark in
      let isNew = !existingLocalBookmarkIds.contains(remoteBookmark.annotationId)
      return isNew
    }
    
    addNewBookmarksToLocalStore(newRemoteBookmarks)
    completion(fetchLocalBookmarks())
  }

  private func addNewBookmarksToLocalStore(_ bookmarks: [AudioBookmark]) {
    bookmarks.forEach { bookmark in
      if let location = bookmark.toTPPBookLocation() {
        registry.addOrReplaceGenericBookmark(location, forIdentifier: book.identifier)
      }
    }
  }

  private func deleteBookmarks(_ bookmarks: [AudioBookmark]) {
    bookmarks.forEach { bookmark in
      deleteBookmark(at: bookmark)
      annotationsManager.deleteBookmark(annotationId: bookmark.annotationId) { _ in }
    }
  }
  
  private func finalizeSync(with bookmarks: [AudioBookmark], completion: (([AudioBookmark]) -> Void)?) {
    isSyncing = false
    completion?(bookmarks)
    completionHandlersQueue.forEach { $0(bookmarks) }
    completionHandlersQueue.removeAll()
  }

  private func replace(oldLocation: AudioBookmark, with newLocation: AudioBookmark) {
    guard
      let oldLocation = oldLocation.toTPPBookLocation(),
      let newLocation = newLocation.toTPPBookLocation() else { return }
    registry.replaceGenericBookmark(oldLocation, with: newLocation, forIdentifier: book.identifier)
  }
}

private extension Array where Element == AudioBookmark {
  func combineAndRemoveDuplicates(with otherArray: [AudioBookmark]) -> [AudioBookmark] {
    let combinedArray = self + otherArray
    var uniqueArray: [AudioBookmark] = []
    
    for location in combinedArray {
      if !uniqueArray.contains(where: { $0.isSimilar(to: location) }) {
        uniqueArray.append(location)
      }
    }
    return uniqueArray
  }
}

extension AudiobookBookmarkBusinessLogic: AudiobookBookmarkDelegate {
  public func saveListeningPosition(at position: TrackPosition, completion: ((String?) -> Void)?) {
    let audioBookmark = position.toAudioBookmark()
    audioBookmark.lastSavedTimeStamp = Date().iso8601
    guard let tppLocation = audioBookmark.toTPPBookLocation() else {
      completion?(nil)
      return
    }

    annotationsManager.postListeningPosition(forBook: self.book.identifier, selectorValue: tppLocation.locationString) { serverId in
      if let serverId {
        audioBookmark.lastSavedTimeStamp = ""
        audioBookmark.annotationId = serverId
      }
    
      self.registry.setLocation(audioBookmark.toTPPBookLocation(), forIdentifier: self.book.identifier)
      completion?(serverId)
    }
  }

  public func saveBookmark(at position: TrackPosition, completion: ((_ position: TrackPosition?) -> Void)? = nil) {
    Task {
      let location = position.toAudioBookmark()
      location.lastSavedTimeStamp = Date().iso8601
      var updatedPosition = position
      updatedPosition.lastSavedTimeStamp = location.lastSavedTimeStamp
      
      defer {
        if let genericLocation = location.toTPPBookLocation() {
          updatedPosition.annotationId = location.annotationId
          registry.addOrReplaceGenericBookmark(genericLocation, forIdentifier: self.book.identifier)
          completion?(updatedPosition)
        }
      }
      
      guard let data = try? JSONEncoder().encode(location), let locationString = String(data: data, encoding: .utf8) else {
        completion?(nil)
        return
      }
      
      if let annotationId = try await annotationsManager.postAudiobookBookmark(forBook: self.book.identifier, selectorValue: locationString) {
        location.annotationId = annotationId
      }
    }
  }
  
  public func fetchBookmarks(for tracks: Tracks, toc: [Chapter], completion: @escaping ([TrackPosition]) -> Void) {
    let localBookmarks: [AudioBookmark] = fetchLocalBookmarks()
    
    self.syncBookmarks(localBookmarks: localBookmarks) { syncedBookmarks in
      let trackPositions = syncedBookmarks.combineAndRemoveDuplicates(with: localBookmarks).compactMap { TrackPosition(audioBookmark: $0, toc: toc, tracks: tracks) }
      completion(trackPositions)
    }
  }

  public func deleteBookmark(at position: TrackPosition, completion: ((Bool) -> Void)? = nil) {
    let bookmark = position.toAudioBookmark()
      deleteBookmark(at: bookmark, completion: completion)
    }
    
    public func deleteBookmark(at bookmark: AudioBookmark, completion: ((Bool) -> Void)? = nil) {
    if let genericLocation = bookmark.toTPPBookLocation() {
      self.registry.deleteGenericBookmark(genericLocation, forIdentifier: self.book.identifier)
    }
    
    guard !bookmark.isUnsynced else {
      completion?(true)
      return
    }
    
    annotationsManager.deleteBookmark(annotationId: bookmark.annotationId) { success in
      completion?(success)
    }
  }
}
