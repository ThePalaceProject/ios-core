//
//  TrackPosition+Annotations.swift
//  Palace
//
//  Created by Maurice Carrier on 5/20/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

public extension TrackPosition {
  func toAudioBookmark() -> AudioBookmark {
    let locator: [String: Any] = [
      "readingOrderItem": track.key,
      "readingOrderItemOffsetMilliseconds": UInt(timestamp * 1000),
      "@type": BookmarkType.locatorAudioBookTime.rawValue,
      "@version": 2
    ]
    return AudioBookmark(locator: locator, type: .locatorAudioBookTime, timeStamp: lastSavedTimeStamp, annotationId: annotationId)
  }

  init?(audioBookmark: AudioBookmark, toc: [Chapter], tracks: Tracks) {
    // Extract the locator dictionary from the audio bookmark.
    guard let locator = audioBookmark.locator["locator"] as? [String: Any] else {
      print("Unsupported locator type: \(audioBookmark.locator)")
      return nil
    }
    
    if let readingOrderItem = locator["readingOrderItem"] as? String,
       let readingOrderItemOffsetMilliseconds = Self.extractOffsetMilliseconds(from: locator["readingOrderItemOffsetMilliseconds"]),
       let track = tracks.track(forKey: readingOrderItem) {
      let timestamp = Double(readingOrderItemOffsetMilliseconds) / 1000.0
      self.init(track: track, timestamp: timestamp, tracks: tracks)
    } else if let href = locator["href"] as? String {
      let timestamp = locator["time"] as? Double ?? 0.0
      if let track = tracks.track(forHref: href) {
        self.init(track: track, timestamp: timestamp, tracks: tracks)
      } else if let part = locator["part"] as? Int,
                let chapter = locator["chapter"] as? String,
                let track = tracks.track(forPart: part, sequence: Int(chapter) ?? 0) {
        self.init(track: track, timestamp: timestamp, tracks: tracks)
      } else {
        guard let chapterIndex = Int(locator["chapter"] as? String ?? ""),
              toc.indices.contains(chapterIndex) else {
          return nil
        }
        let track = toc[chapterIndex].position.track
        self.init(track: track, timestamp: timestamp, tracks: tracks)
      }
    } else if let part = locator["part"] as? Int,
              let chapter = locator["chapter"] as? Int,
              let track = tracks.track(forPart: part, sequence: chapter) {
      let timestamp = Double(locator["time"] as? Int ?? 0) / 1000.0
      self.init(track: track, timestamp: timestamp, tracks: tracks)
    } else if let chapterIndex = Int(locator["chapter"] as? String ?? ""),
              toc.indices.contains(chapterIndex) {
      let track = toc[chapterIndex].position.track
      let timestamp = Double(locator["time"] as? Int ?? 0) / 1000.0
      self.init(track: track, timestamp: timestamp, tracks: tracks)
    } else if let chapterIndex = locator["chapter"] as? Int,
      toc.count - 1 > chapterIndex {
      let track = toc[chapterIndex].position.track
      let timestamp = Double(locator["time"] as? Int ?? 0) / 1000.0
      self.init(track: track, timestamp: timestamp, tracks: tracks)
    } else {
      print("Unable to find a valid track for the provided locator.")
      return nil
    }
    
    // Assign additional properties from the audio bookmark.
    self.annotationId = audioBookmark.annotationId
    self.lastSavedTimeStamp = audioBookmark.lastSavedTimeStamp
  }

  private static func extractOffsetMilliseconds(from value: Any?) -> UInt? {
    if let uintValue = value as? UInt {
      return uintValue
    } else if let intValue = value as? Int, intValue >= 0 {
      return UInt(intValue)
    } else if let doubleValue = value as? Double, doubleValue >= 0 {
      return UInt(doubleValue)
    }
    return nil
  }
}
