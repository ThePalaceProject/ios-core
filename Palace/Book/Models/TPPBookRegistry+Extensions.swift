//
//  TPPBookRegistry+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 6/17/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import PalaceAudiobookToolkit

@objc extension TPPBookRegistry {
  func syncLocation(for book: TPPBook, completion: @escaping (AudioBookmark?) -> Void) {
    Task {
      let readPos = await TPPAnnotations.syncReadingPosition(ofBook: book, toURL: book.annotationsURL) as? AudioBookmark
      completion(readPos)
    }
  }
}
