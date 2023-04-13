//
//  TPPBookCellDelegate+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 4/12/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import NYPLAudiobookToolkit

extension TPPBookCellDelegate: AudiobookPlaybackPositionDelegate {
  public func post(location: String) {
    TPPAnnotations.postListeningPosition(forBook: self.book.identifier, selectorValue: location)
  }
  
  public func saveBookmark(at location: String) {
    TPPAnnotations.postAudiobookBookmark(forBook: self.book.identifier, selectorValue: location)
  }
  
  public func fetchBookmarks(for audiobook: String, completion: @escaping ([NYPLAudiobookToolkit.ChapterLocation]) -> ()) {
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
}
