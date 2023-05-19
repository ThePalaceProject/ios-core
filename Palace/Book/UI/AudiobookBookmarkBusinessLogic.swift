//
//  AudiobookBookmarkBusinessLogic.swift
//  Palace
//
//  Created by Maurice Carrier on 4/12/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import NYPLAudiobookToolkit

@objc public class AudiobookBookmarkBusinessLogic: NSObject, AudiobookBookmarkDelegate {
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

  public func saveListeningPosition(at location: String, completion: ((_ serverID: String?) -> Void)? = nil) {
    annotationsManager.postListeningPosition(forBook: self.book.identifier, selectorValue: location, completion: completion)
  }

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

  public func fetchBookmarks(completion: @escaping ([NYPLAudiobookToolkit.ChapterLocation]) -> Void) {
    let localBookmarks: [ChapterLocation] = fetchLocalBookmarks()

    fetchServerBookmarks { [weak self] serverBookmarks in
      self?.syncBookmarks(localBookmarks: localBookmarks)
      completion(serverBookmarks.combineAndRemoveDuplicates(with: localBookmarks))
    }
  }

  private func fetchLocalBookmarks() -> [ChapterLocation] {
    registry.genericBookmarksForIdentifier(book.identifier).compactMap {
        guard let localData = $0.locationString.data(using: .utf8),
                let location = try? JSONDecoder().decode(ChapterLocation.self, from: localData) else { return nil }
        return location
      }
  }

  private func fetchServerBookmarks(completion: @escaping ([NYPLAudiobookToolkit.ChapterLocation]) -> Void) {
    annotationsManager.getServerBookmarks(forBook: book.identifier, atURL: book.annotationsURL, motivation: .bookmark) { serverBookmarks in
        guard let bookmarks = serverBookmarks as? [AudioBookmark] else {
            completion([])
            return
        }

      let serverBookmarks = bookmarks.compactMap { ChapterLocation(audioBookmark: $0) }
      completion(serverBookmarks)
    }
  }
  
  func syncBookmarks(localBookmarks: [ChapterLocation], completion: (() -> Void)? = nil) {
     Task {
      guard !isSyncing else { return }
      isSyncing = true
    
      let unsyncedBookmarks = localBookmarks.filter { $0.annotationId.isEmpty }
      
      for bookmark in unsyncedBookmarks {
        let data = bookmark.toData()
        guard let locationString = String(data: data, encoding: .utf8) else {
          continue
        }
        
        if let annotationId = try await annotationsManager.postAudiobookBookmark(forBook: self.book.identifier, selectorValue: locationString) {
          if let updatedBookmark = bookmark.copy() as? ChapterLocation {
            updatedBookmark.annotationId = annotationId
            replace(oldLocation: bookmark, with: updatedBookmark)
          }
        }
      }

      fetchServerBookmarks { [weak self] remoteBookmarks in
        guard let self = self, !remoteBookmarks.isEmpty else {
          return
        }

        var updatedLocalBookmarks = self.fetchLocalBookmarks()
        let unsyncedRemoteBookmarks = remoteBookmarks.filter { remoteBookmark in
          !updatedLocalBookmarks.contains(where: { localBookmark in
            localBookmark.isSimilar(to: remoteBookmark)
          })
        }
  
        unsyncedRemoteBookmarks.forEach {
          if let genericLocation = $0.toTPPBookLocation() {
            self.registry.addOrReplaceGenericBookmark(genericLocation, forIdentifier: self.book.identifier)
          }
        }
        
        updatedLocalBookmarks = self.fetchLocalBookmarks()
//        let serverBookmarksToDelete = remoteBookmarks.filter { remoteBookmark in
//          !updatedLocalBookmarks.contains(where: { localBookmark in
//            localBookmark.isSimilar(to: remoteBookmark) && !localBookmark.annotationId.isEmpty
//          })
//        }
        
        let localBookmarksToDelete = remoteBookmarks.filter { remoteBookmark in
          updatedLocalBookmarks.contains(where: { localBookmark in
            localBookmark.isSimilar(to: remoteBookmark) && localBookmark.annotationId.isEmpty
          })
        }
        
        localBookmarksToDelete.forEach { self.deleteBookmark(at: $0) { _ in
          self.isSyncing = false
          completion?()
        }}
        
        
      }
    }
  }
  
  private func replace(oldLocation: ChapterLocation, with newLocation: ChapterLocation) {
    guard
      let oldLocation = oldLocation.toTPPBookLocation(),
      let newLocation = newLocation.toTPPBookLocation() else { return }
    registry.replaceGenericBookmark(oldLocation, with: newLocation, forIdentifier: book.identifier)
  }

  public func deleteBookmark(at location: ChapterLocation, completion: @escaping (Bool) -> Void) {
    if let genericLocation = location.toTPPBookLocation() {
      self.registry.deleteGenericBookmark(genericLocation, forIdentifier: self.book.identifier)
    }
  
    annotationsManager.deleteBookmark(annotationId: location.annotationId) { success in
        completion(success)
      }
    }
  }

extension Array where Element == ChapterLocation {
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

extension ChapterLocation: NSCopying {
  public func copy(with zone: NSZone? = nil) -> Any {
    let copy = ChapterLocation(
      number: number,
      part: part,
      duration: duration,
      startOffset: chapterOffset,
      playheadOffset: playheadOffset,
      title: title,
      audiobookID: audiobookID
    )
    copy.lastSavedTimeStamp = self.lastSavedTimeStamp
    copy.annotationId = self.annotationId
    return copy
  }
  
  
  func toTPPBookLocation() -> TPPBookLocation? {
    guard let updatedLocationString = String(data: toData(), encoding: .utf8) else { return nil }
    return TPPBookLocation.init(locationString: updatedLocationString, renderer: "NYPLAudiobookToolkit")
  }

  func isSimilar(to location: ChapterLocation) -> Bool {
    type == location.type &&
    number == location.number &&
    part == location.part &&
    chapterOffset == location.chapterOffset &&
    playheadOffset == location.playheadOffset &&
    title == location.title &&
    audiobookID == location.audiobookID &&
    duration == location.duration
  }
}
