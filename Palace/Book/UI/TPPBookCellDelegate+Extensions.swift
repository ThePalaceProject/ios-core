//
//  TPPBookCellDelegate+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 4/12/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import NYPLAudiobookToolkit

@objc extension TPPBookCellDelegate {
  public func saveListeningPosition(at location: String, completion: ((_ serverID: String?) -> Void)? = nil) {
    TPPAnnotations.postListeningPosition(forBook: self.book.identifier, selectorValue: location, completion: completion)
  }

  public func saveBookmark(at location: ChapterLocation, completion: ((_ location: ChapterLocation?) -> Void)? = nil) {
    
    let data = location.toData()
    if let locationString = String(data: data, encoding: .utf8) {
      TPPAnnotations.postAudiobookBookmark(forBook: self.book.identifier, selectorValue: locationString) { annotationId in
        location.annotationId = annotationId ?? "L\(UUID().uuidString)"
        location.lastSavedTimeStamp = Date().iso8601

        if let updatedLocationString = String(data: location.toData(), encoding: .utf8) {
          if let genericLocation = TPPBookLocation.init(locationString: updatedLocationString, renderer: "NYPLAudiobookToolkit") {
            TPPBookRegistry.shared.addGenericBookmark(genericLocation, forIdentifier: location.audiobookID)
          }
        }
        completion?(location)
      }
    }
  }

  public func fetchBookmarks(for audiobook: String, completion: @escaping ([NYPLAudiobookToolkit.ChapterLocation]) -> Void) {
      guard let book = TPPBookRegistry.shared.book(forIdentifier: audiobook) else {
          completion([])
          return
      }

    let localBookmarks: [ChapterLocation] = TPPBookRegistry.shared.genericBookmarksForIdentifier(book.identifier).compactMap {
        guard let localData = $0.locationString.data(using: .utf8),
                let location = try? JSONDecoder().decode(ChapterLocation.self, from: localData) else { return nil }
        return location
      }

      TPPAnnotations.getServerBookmarks(forBook: audiobook, atURL: book.annotationsURL) { [weak self] serverBookmarks in
          guard let bookmarks = serverBookmarks as? [AudioBookmark] else {
              completion(localBookmarks)
              return
          }

          let serverBookmarks = bookmarks.compactMap { ChapterLocation(audioBookmark: $0) }
          self?.syncBookmarks(localBookmarks: localBookmarks, remoteBookmarks: serverBookmarks)
          completion(serverBookmarks.combinedAndRemoveDuplicates(with: localBookmarks))
      }
  }
  
  private func syncBookmarks(localBookmarks: [ChapterLocation], remoteBookmarks: [ChapterLocation]) {
    DispatchQueue.global().async { [weak self] in
      let unsavedBookmarks = localBookmarks.filter { object in
        !remoteBookmarks.contains(where: { $0.isSimilar(to: object) })
      }
      
      unsavedBookmarks.forEach {
        self?.saveBookmark(at: $0)
      }
    }
  }

  public func deleteBookmark(at location: ChapterLocation, completion: @escaping (Bool) -> Void) {
    TPPAnnotations.deleteBookmark(annotationId: location.annotationId) { success in
      if success {
        if let locationString = String(data: location.toData(), encoding: .utf8),
           let genericLocation = TPPBookLocation.init(locationString: locationString, renderer: "NYPLAudiobookToolkit") {
          TPPBookRegistry.shared.deleteGenericBookmark(genericLocation, forIdentifier: location.annotationId)
        }
      }
  
      completion(success)
    }
  }
}

extension Array where Element == ChapterLocation {
    func combinedAndRemoveDuplicates(with otherArray: [ChapterLocation]) -> [ChapterLocation] {
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
