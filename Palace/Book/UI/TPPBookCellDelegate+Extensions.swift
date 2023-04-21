//
//  TPPBookCellDelegate+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 4/12/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import NYPLAudiobookToolkit

extension TPPBookCellDelegate {
  public func saveListeningPosition(at location: String, completion: ((_ serverID: String?) -> Void)? = nil) {
    TPPAnnotations.postListeningPosition(forBook: self.book.identifier, selectorValue: location, completion: completion)
  }
  
  public func saveBookmark(at location: String, completion: ((_ serverID: String?) -> Void)? = nil) {
    TPPAnnotations.postAudiobookBookmark(forBook: self.book.identifier, selectorValue: location, completion: completion)
  }
  
  public func fetchBookmarks(for audiobook: String, completion: @escaping ([NYPLAudiobookToolkit.ChapterLocation]) -> Void) {
    guard let book = TPPBookRegistry.shared.book(forIdentifier: audiobook) else {
      completion([])
      return
    }
    
    TPPAnnotations.getServerBookmarks(forBook: audiobook, atURL: book.annotationsURL) { serverBookmarks in
      
      guard let bookmarks = serverBookmarks as? [AudioBookmark] else {
        completion([])
        return
      }
      
      completion(bookmarks.compactMap { ChapterLocation(audioBookmark: $0) })
    }
  }
  
  public func deleteBookmark(at location: ChapterLocation, completion: @escaping (Bool) -> Void) {
    TPPAnnotations.deleteBookmark(annotationId: location.annotationId, completionHandler: completion)
  }
}
