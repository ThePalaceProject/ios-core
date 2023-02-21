//
//  TPPBookRegistry+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 6/17/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import NYPLAudiobookToolkit

@objc extension TPPBookRegistry {
  func syncLocation(for book: TPPBook, completion: @escaping (ChapterLocation?) -> Void) {
    TPPAnnotations.syncReadingPosition(ofBook: book.identifier, toURL: book.annotationsURL) { readPos in
      
      guard let bookmark = readPos as? AudioBookmark else {
        completion(nil)
        return
      }

      completion(ChapterLocation(audioBookmark: bookmark))
    }
  }
}

extension ChapterLocation {

  convenience init(audioBookmark: AudioBookmark) {
    self.init(
      number: audioBookmark.chapter,
      part: audioBookmark.part,
      duration: Double(audioBookmark.duration/1000),
      startOffset: 0,
      playheadOffset: Double(audioBookmark.time/1000),
      title: audioBookmark.title,
      audiobookID: audioBookmark.audiobookID
    )
  }
}
