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
  
  private func fetchLocalBookmarks() -> [ChapterLocation] {
    return registry.genericBookmarksForIdentifier(book.identifier).compactMap { bookmark in
      guard
        let localData = bookmark.locationString.data(using: .utf8),
        let location = try? JSONDecoder().decode(ChapterLocation.self, from: localData)
      else {
        return nil
      }
      
      return location
    }
  }
  
  private func fetchServerBookmarks(completion: @escaping ([PalaceAudiobookToolkit.ChapterLocation]) -> Void) {
    annotationsManager.getServerBookmarks(forBook: book.identifier, atURL: book.annotationsURL, motivation: .bookmark) { serverBookmarks in
      guard let audioBookmarks = serverBookmarks as? [AudioBookmark] else {
        completion([])
        return
      }
      
      let chapterLocations = audioBookmarks.compactMap(ChapterLocation.init)
      completion(chapterLocations)
    }
  }
  
  private var completionHandlersQueue: [([ChapterLocation]) -> Void] = []

  func syncBookmarks(localBookmarks: [ChapterLocation], completion: (([ChapterLocation]) -> Void)? = nil) {
    guard !isSyncing else {
      if let completion = completion {
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
  
  private func uploadUnsyncedBookmarks(_ localBookmarks: [ChapterLocation]) async {
    let unsyncedLocalBookmarks = localBookmarks.filter { $0.annotationId.isEmpty }
    
    for bookmark in unsyncedLocalBookmarks {
      do {
        try await uploadBookmark(bookmark)
      } catch {
        ATLog(.debug, "Failed to save annotation with error: \(error.localizedDescription)")
      }
    }
  }
  
  private func uploadBookmark(_ bookmark: ChapterLocation) async throws {
    let data = bookmark.toData()
    guard let locationString = String(data: data, encoding: .utf8) else { return }
    
    guard let annotationId = try await annotationsManager.postAudiobookBookmark(forBook: self.book.identifier, selectorValue: locationString) else {
      return
    }
    
    replaceBookmarkInLocalStore(bookmark, withAnnotationId: annotationId)
  }

  private func replaceBookmarkInLocalStore(_ bookmark: ChapterLocation, withAnnotationId annotationId: String) {
    if let updatedBookmark = bookmark.copy() as? ChapterLocation {
      updatedBookmark.annotationId = annotationId
      replace(oldLocation: bookmark, with: updatedBookmark)
    }
  }
  
  private func updateLocalBookmarks(with remoteBookmarks: [ChapterLocation], completion: @escaping ([ChapterLocation]) -> Void) {
    var updatedLocalBookmarks = fetchLocalBookmarks()

    guard TPPAnnotations.syncIsPossibleAndPermitted() else {
      completion(updatedLocalBookmarks)
      return
    }
    
    let localBookmarksToDelete = updatedLocalBookmarks.filter { localBookmark in
      !remoteBookmarks.contains(where: { remoteBookmark in
        remoteBookmark.isSimilar(to: localBookmark)
      })
    }
    
    deleteBookmarks(localBookmarksToDelete)
    
    updatedLocalBookmarks.removeAll(where: { localBookmark in
      localBookmarksToDelete.contains(localBookmark)
    })
    
    completion(updatedLocalBookmarks)
  }
  
  private func deleteBookmarks(_ bookmarks: [ChapterLocation]) {
    bookmarks.forEach { bookmark in
      deleteBookmark(at: bookmark)
      if !bookmark.annotationId.isEmpty {
        annotationsManager.deleteBookmark(annotationId: bookmark.annotationId) { _ in }
      }
    }
  }
  
  private func finalizeSync(with bookmarks: [ChapterLocation], completion: (([ChapterLocation]) -> Void)?) {
    isSyncing = false
    completion?(bookmarks)
    completionHandlersQueue.forEach { $0(bookmarks) }
    completionHandlersQueue.removeAll()
  }

  private func replace(oldLocation: ChapterLocation, with newLocation: ChapterLocation) {
    guard
      let oldLocation = oldLocation.toTPPBookLocation(),
      let newLocation = newLocation.toTPPBookLocation() else { return }
    registry.replaceGenericBookmark(oldLocation, with: newLocation, forIdentifier: book.identifier)
  }
}

private extension Array where Element == ChapterLocation {
  func combineAndRemoveDuplicates(with otherArray: [ChapterLocation]) -> [ChapterLocation] {
    let combinedArray = self + otherArray
    var uniqueArray: [ChapterLocation] = []
    
    for location in combinedArray {
      if !uniqueArray.contains(where: { $0.isSimilar(to: location) }) {
        uniqueArray.append(location)
      }
    }
    return uniqueArray
  }
}

extension AudiobookBookmarkBusinessLogic: AudiobookPlaybackPositionDelegate {
  public func saveListeningPosition(at location: String, completion: ((_ serverID: String?) -> Void)? = nil) {
    annotationsManager.postListeningPosition(forBook: self.book.identifier, selectorValue: location, completion: completion)
  }
}

extension AudiobookBookmarkBusinessLogic: AudiobookBookmarkDelegate {
  public func saveBookmark(at location: ChapterLocation, completion: ((_ location: ChapterLocation?) -> Void)? = nil) {
    Task {
      location.lastSavedTimeStamp = Date().iso8601
      
      defer {
        if let genericLocation = location.toTPPBookLocation() {
          registry.addOrReplaceGenericBookmark(genericLocation, forIdentifier: self.book.identifier)
          completion?(location)
        }
      }
      
      let data = location.toData()
      guard let locationString = String(data: data, encoding: .utf8) else {
        return
      }
      
      if let annotationId = try await annotationsManager.postAudiobookBookmark(forBook: self.book.identifier, selectorValue: locationString) {
        location.annotationId = annotationId
      }
    }
  }
  
  public func fetchBookmarks(completion: @escaping ([PalaceAudiobookToolkit.ChapterLocation]) -> Void) {
    let localBookmarks: [ChapterLocation] = fetchLocalBookmarks()

    fetchServerBookmarks { [weak self] serverBookmarks in
      self?.syncBookmarks(localBookmarks: localBookmarks)
      completion(serverBookmarks.combineAndRemoveDuplicates(with: localBookmarks))
    }
  }
  
  public func deleteBookmark(at location: ChapterLocation, completion: ((Bool) -> Void)? = nil) {
    if let genericLocation = location.toTPPBookLocation() {
      self.registry.deleteGenericBookmark(genericLocation, forIdentifier: self.book.identifier)
    }
    
    annotationsManager.deleteBookmark(annotationId: location.annotationId) { success in
      completion?(success)
    }
  }
}
