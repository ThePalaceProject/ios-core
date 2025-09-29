//
//  TrackPosition+Annotations.swift
//  Palace
//
//  Created by Maurice Carrier on 5/20/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import PalaceAudiobookToolkit

public extension TrackPosition {
  func toAudioBookmark() -> AudioBookmark {
    let offsetMilliseconds: Int
    if timestamp >= 0 {
      offsetMilliseconds = Int(timestamp * 1000)
    } else {
      ATLog(.debug, "Warning: Negative timestamp encountered. Defaulting to 0.")
      offsetMilliseconds = 0
    }

    return AudioBookmark(
      type: .locatorAudioBookTime,
      version: 2,
      timeStamp: lastSavedTimeStamp,
      annotationId: annotationId,
      readingOrderItem: track.key,
      readingOrderItemOffsetMilliseconds: offsetMilliseconds
    )
  }

  init?(audioBookmark: AudioBookmark, toc: [Chapter], tracks: Tracks) {
    guard audioBookmark.type == .locatorAudioBookTime else {
      ATLog(.debug, "Unsupported bookmark type: \(audioBookmark.type)")
      return nil
    }

    if audioBookmark.version == 2 {
      guard let readingOrderItem = audioBookmark.readingOrderItem,
            let readingOrderItemOffsetMilliseconds = audioBookmark.readingOrderItemOffsetMilliseconds,
            let track = tracks.track(forKey: readingOrderItem)
      else {
        ATLog(.debug, "Unable to find a valid track for the provided locator.")
        return nil
      }
      let timestamp = Double(readingOrderItemOffsetMilliseconds) / 1000.0
      self.init(track: track, timestamp: timestamp, tracks: tracks)
    } else {
      if let initializedFromReadingOrderItem = TrackPosition.initializeFromReadingOrderItem(
        audioBookmark: audioBookmark,
        tracks: tracks
      ) {
        self = initializedFromReadingOrderItem
      } else if let initializedFromHref = TrackPosition.initializeFromHref(
        audioBookmark: audioBookmark,
        toc: toc,
        tracks: tracks
      ) {
        self = initializedFromHref
      } else if let initializedFromPartAndChapter = TrackPosition.initializeFromPartAndChapter(
        audioBookmark: audioBookmark,
        toc: toc,
        tracks: tracks
      ) {
        self = initializedFromPartAndChapter
      } else if let initializedFromChapterIndex = TrackPosition.initializeFromChapterIndex(
        audioBookmark: audioBookmark,
        toc: toc
      ) {
        self = initializedFromChapterIndex
      } else {
        ATLog(.debug, "Unable to find a valid track for the provided locator.")
        return nil
      }
    }

    annotationId = audioBookmark.annotationId
    lastSavedTimeStamp = audioBookmark.lastSavedTimeStamp ?? ""
  }

  private static func initializeFromReadingOrderItem(audioBookmark: AudioBookmark, tracks: Tracks) -> TrackPosition? {
    guard let readingOrderItem = audioBookmark.readingOrderItem,
          let readingOrderItemOffsetMilliseconds = audioBookmark.readingOrderItemOffsetMilliseconds,
          let track = tracks.track(forKey: readingOrderItem) ?? tracks.track(forTitle: readingOrderItem)
    else {
      return nil
    }
    let timestamp = Double(readingOrderItemOffsetMilliseconds) / 1000.0
    return TrackPosition(track: track, timestamp: timestamp, tracks: tracks)
  }

  private static func initializeFromHref(
    audioBookmark: AudioBookmark,
    toc _: [Chapter],
    tracks: Tracks
  ) -> TrackPosition? {
    guard let href = audioBookmark.readingOrderItem else {
      return nil
    }
    let timestamp = Double(audioBookmark.time ?? 0) / 1000.0
    if let track = tracks.track(forHref: href) {
      return TrackPosition(track: track, timestamp: timestamp, tracks: tracks)
    } else if let part = audioBookmark.part,
              let chapter = Int(audioBookmark.chapter ?? ""),
              let track = tracks.track(forPart: part, sequence: chapter)
    {
      return TrackPosition(track: track, timestamp: timestamp, tracks: tracks)
    }
    return nil
  }

  private static func initializeFromPartAndChapter(
    audioBookmark: AudioBookmark,
    toc _: [Chapter],
    tracks: Tracks
  ) -> TrackPosition? {
    guard let part = audioBookmark.part,
          let chapter = Int(audioBookmark.chapter ?? ""),
          let track = tracks.track(forPart: part, sequence: chapter)
    else {
      return nil
    }
    let timestamp = Double(audioBookmark.time ?? 0) / 1000.0
    return TrackPosition(track: track, timestamp: timestamp, tracks: tracks)
  }

  private static func initializeFromChapterIndex(audioBookmark: AudioBookmark, toc: [Chapter]) -> TrackPosition? {
    guard let chapterIndex = Int(audioBookmark.chapter ?? ""),
          toc.indices.contains(chapterIndex)
    else {
      return nil
    }
    let track = toc[chapterIndex].position.track
    let timestamp = Double(audioBookmark.time ?? 0) / 1000.0
    return TrackPosition(track: track, timestamp: timestamp, tracks: toc[chapterIndex].position.tracks)
  }
}
