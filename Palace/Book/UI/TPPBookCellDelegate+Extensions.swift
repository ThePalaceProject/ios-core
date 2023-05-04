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

  public func saveBookmark(at location: String, completion: ((_ serverID: String?) -> Void)? = nil) {

    var localAnnotationlId: String?
  
    TPPAnnotations.postAudiobookBookmark(forBook: self.book.identifier, selectorValue: location) { annotationId in
      if let genericLocation = TPPBookLocation.init(locationString: location, renderer: "NYPLAudiobookToolkit") {
        TPPBookRegistry.shared.addGenericBookmark(genericLocation, forIdentifier: self.book.identifier)
        localAnnotationlId = "L\(UUID().uuidString)"
      }

      completion?(annotationId ?? localAnnotationlId)
    }
  }

  public func fetchBookmarks(for audiobook: String, completion: @escaping ([NYPLAudiobookToolkit.ChapterLocation]) -> Void) {
      guard let book = TPPBookRegistry.shared.book(forIdentifier: audiobook) else {
          completion([])
          return
      }

      let localBookmarks: [ChapterLocation] = TPPBookRegistry.shared.genericBookmarksForIdentifier(audiobook).compactMap {
        guard let localData = $0.locationString.data(using: .utf8),
                let location = try? JSONDecoder().decode(ChapterLocation.self, from: localData) else { return nil }
        return location
      }

      TPPAnnotations.getServerBookmarks(forBook: audiobook, atURL: book.annotationsURL) { serverBookmarks in
          guard let bookmarks = serverBookmarks as? [AudioBookmark] else {
              completion(localBookmarks)
              return
          }

          let serverChapterLocations = bookmarks.compactMap { ChapterLocation(audioBookmark: $0) }

          let combinedBookmarks = localBookmarks + serverChapterLocations
          completion(combinedBookmarks.removingDuplicates())
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
