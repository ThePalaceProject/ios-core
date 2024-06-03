//
//  TrackPosition+Annotations.swift
//  Palace
//
//  Created by Maurice Carrier on 5/20/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

public extension TrackPosition {
  func toAudioBookmark() -> AudioBookmark {
    let locator = AudioBookmark.LocatorAudioBookTime2(
      readingOrderItem: track.key,
      readingOrderItemOffsetMilliseconds: UInt(timestamp * 1000)
    )
    return AudioBookmark(locator: locator, timeStamp: lastSavedTimeStamp, annotationId: annotationId)
  }
  
  init?(audioBookmark: AudioBookmark, toc: [Chapter], tracks: Tracks) {
    switch audioBookmark.locator {
    case let locator as AudioBookmark.LocatorAudioBookTime2:
      guard let track = tracks.track(forKey: locator.readingOrderItem) else { return nil }
      let timestamp = Double(locator.readingOrderItemOffsetMilliseconds) / 1000.0
      self.init(track: track, timestamp: timestamp, tracks: tracks)
      
    case let locator as AudioBookmark.LocatorAudioBookTime1:
      let timestamp = Double(locator.time)
      if let track = tracks.track(forPart: Int(locator.part), sequence: Int(locator.chapter)) {
        self.init(track: track, timestamp: timestamp, tracks: tracks)
      } else {
        guard let chapterIndex = Int(exactly: locator.chapter), toc.indices.contains(chapterIndex) else { return nil }
        let track = toc[chapterIndex].position.track
        self.init(track: track, timestamp: timestamp, tracks: tracks)
      }
      
    default:
      return nil
    }
    
    self.annotationId = audioBookmark.annotationId
    self.lastSavedTimeStamp = audioBookmark.lastSavedTimeStamp
  }
}
