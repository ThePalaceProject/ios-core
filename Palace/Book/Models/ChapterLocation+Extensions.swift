//
//  ChapterLocation+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 5/29/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

extension ChapterLocation {
  func toTPPBookLocation() -> TPPBookLocation? {
    guard let updatedLocationString = String(data: toData(), encoding: .utf8) else { return nil }
    return TPPBookLocation.init(locationString: updatedLocationString, renderer: "PalaceAudiobookToolkit")
  }
}

extension ChapterLocation {
  convenience init(audioBookmark: AudioBookmark) {
    self.init(
      number: audioBookmark.chapter,
      part: audioBookmark.part,
      duration: Double(audioBookmark.duration/1000),
      startOffset: Double((audioBookmark.startOffset ?? 0)/1000),
      playheadOffset: Double(audioBookmark.time/1000),
      title: audioBookmark.title,
      audiobookID: audioBookmark.audiobookID,
      lastSavedTimeStamp: audioBookmark.timeStamp,
      annotationId: audioBookmark.annotationId
    )
  }
}
