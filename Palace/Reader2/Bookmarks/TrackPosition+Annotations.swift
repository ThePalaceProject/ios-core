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
    return AudioBookmark(locator: locator)
  }

  init?(audioBookmark: AudioBookmark, toc: [Chapter], tracks: Tracks) {
    if let locator = audioBookmark.locator as? AudioBookmark.LocatorAudioBookTime2,
       let track = tracks.track(forKey: locator.readingOrderItem) {
      let timestamp = Double(locator.readingOrderItemOffsetMilliseconds) / 1000.0
      self.init(track: track, timestamp: timestamp, tracks: tracks)
    } else if let locator = audioBookmark.locator as? AudioBookmark.LocatorAudioBookTime1 {
      if let track = tracks.track(forPart: Int(locator.part), sequence: Int(locator.chapter)) {
        let timestamp = Double(locator.time)
        self.init(track: track, timestamp: timestamp, tracks: tracks)
      } else {
        let track = toc[Int(locator.chapter)].position.track
        let timestamp = Double(locator.time)
        self.init(track: track, timestamp: timestamp, tracks: tracks)
      }
    } else {
      return nil
    }
  }
}
