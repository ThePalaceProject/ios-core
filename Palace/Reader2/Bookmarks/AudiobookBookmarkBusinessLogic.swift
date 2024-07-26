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
  private let queue = DispatchQueue(label: "com.palace.audiobookBookmarkBusinessLogic", attributes: .concurrent)
  private var debounceTimer: Timer?
  private let debounceInterval: TimeInterval = 1.0
  private var completionHandlersQueue: [([AudioBookmark]) -> Void] = []

  @objc convenience init(book: TPPBook) {
    self.init(book: book, registry: TPPBookRegistry.shared, annotationsManager: TPPAnnotationsWrapper())
  }
  
  init(book: TPPBook, registry: TPPBookRegistryProvider, annotationsManager: AnnotationsManager) {
    self.book = book
    self.registry = registry
    self.annotationsManager = annotationsManager
  }
  
  // MARK: - Bookmark Management
  
  public func saveListeningPosition(at position: TrackPosition, completion: ((String?) -> Void)?) {
    let audioBookmark = position.toAudioBookmark()
    audioBookmark.lastSavedTimeStamp = Date().iso8601
    guard let tppLocation = audioBookmark.toTPPBookLocation() else {
      completion?(nil)
      return
    }
    
    annotationsManager.postListeningPosition(forBook: self.book.identifier, selectorValue: tppLocation.locationString) { response in
      if let response {
        audioBookmark.lastSavedTimeStamp = response.timeStamp ?? ""
        audioBookmark.annotationId = response.serverId ?? ""
        self.registry.setLocation(audioBookmark.toTPPBookLocation(), forIdentifier: self.book.identifier)
        completion?(response.timeStamp)
      } else {
        completion?(nil)
      }
    }
  }
  
  public func saveBookmark(at position: TrackPosition, completion: ((_ position: TrackPosition?) -> Void)? = nil) {
    debounce {
      Task {
        let location = position.toAudioBookmark()
        var updatedPosition = position
        
        defer {
          updatedPosition.lastSavedTimeStamp = location.lastSavedTimeStamp ?? Date().iso8601
          updatedPosition.annotationId = location.annotationId
          if let updatedLocation = updatedPosition.toAudioBookmark().toTPPBookLocation() {
            self.registry.addOrReplaceGenericBookmark(updatedLocation, forIdentifier: self.book.identifier)
          }
          completion?(updatedPosition)
        }
        
        guard let data = location.toData(), let locationString = String(data: data, encoding: .utf8) else {
          Log.error(#file, "Failed to encode location data for bookmark.")
          completion?(nil)
          return
        }
        
        if let annotationResponse = try? await self.annotationsManager.postAudiobookBookmark(forBook: self.book.identifier, selectorValue: locationString) {
          location.annotationId = annotationResponse?.serverId ?? ""
          location.lastSavedTimeStamp = annotationResponse?.timeStamp ?? ""
        }
      }
    }
  }
  
  public func fetchBookmarks(for tracks: Tracks, toc: [Chapter], completion: @escaping ([TrackPosition]) -> Void) {
    queue.async {
      let localBookmarks: [AudioBookmark] = self.fetchLocalBookmarks()
      
      self.syncBookmarks(localBookmarks: localBookmarks) { syncedBookmarks in
        let trackPositions = syncedBookmarks.combineAndRemoveDuplicates(with: localBookmarks).compactMap { TrackPosition(audioBookmark: $0, toc: toc, tracks: tracks) }
        DispatchQueue.main.async {
          completion(trackPositions)
        }
      }
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
  
  // MARK: - Sync Logic
  
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
          let locationString = String(data: data, encoding: .utf8) else { return }
    
    guard let annotationResponse = try await annotationsManager.postAudiobookBookmark(forBook: self.book.identifier, selectorValue: locationString) else {
      return
    }
    
    updateLocalBookmark(bookmark, with: annotationResponse)
  }
  
  private func updateLocalBookmark(_ bookmark: AudioBookmark, with annotationResponse: AnnotationResponse) {
    if let updatedBookmark = bookmark.copy() as? AudioBookmark {
      updatedBookmark.annotationId = annotationResponse.serverId ?? ""
      updatedBookmark.lastSavedTimeStamp = annotationResponse.timeStamp ?? ""
      replace(oldLocation: bookmark, with: updatedBookmark)
    }
  }
  
  private func updateLocalBookmarks(with remoteBookmarks: [AudioBookmark], completion: @escaping ([AudioBookmark]) -> Void) {
    let localBookmarks = fetchLocalBookmarks()
    
    guard annotationsManager.syncIsPossibleAndPermitted else {
      completion(localBookmarks)
      return
    }
    
    var updatedLocalBookmarks = localBookmarks
    
    let newRemoteBookmarks = remoteBookmarks.filter { remoteBookmark in
      let isSimilar = localBookmarks.contains { $0.isSimilar(to: remoteBookmark) }
      return !isSimilar
    }
    
    addNewBookmarksToLocalStore(newRemoteBookmarks)
    
    updatedLocalBookmarks = fetchLocalBookmarks()
    
    completion(updatedLocalBookmarks)
  }
  
  private func addNewBookmarksToLocalStore(_ bookmarks: [AudioBookmark]) {
    bookmarks.forEach { bookmark in
      bookmark.annotationId = UUID().uuidString
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
  
  // MARK: - Helpers
  
  private func debounce(action: @escaping () -> Void) {
    debounceTimer?.invalidate()
    debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { _ in
      action()
    }
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

private extension Array {
  func chunked(into size: Int) -> [[Element]] {
    stride(from: 0, to: count, by: size).map {
      Array(self[$0..<Swift.min($0 + size, count)])
    }
  }
}

extension AudiobookBookmarkBusinessLogic: AudiobookBookmarkDelegate {}
