//
//  AudioBookmark.swift
//  Palace
//
//  Created by Maurice Carrier on 6/16/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

@objc public class AudioBookmark: NSObject, Bookmark, Codable, NSCopying {
  enum BookmarkType: String, Codable {
    case locatorAudioBookTime = "LocatorAudioBookTime"
  }
  
  struct LocatorAudioBookTime1: Codable {
    let title: String
    let chapter: UInt
    let part: UInt
    let duration: UInt
    let startOffset: UInt?
    let time: UInt
    let audiobookID: String
    
    enum CodingKeys: String, CodingKey {
      case title
      case chapter
      case part
      case duration
      case startOffset
      case time
      case audiobookID
    }
  }
  
  struct LocatorAudioBookTime2: Codable {
    let readingOrderItem: String
    let readingOrderItemOffsetMilliseconds: UInt
    
    enum CodingKeys: String, CodingKey {
      case type = "@type"
      case version = "@version"
      case readingOrderItem
      case readingOrderItemOffsetMilliseconds
    }
    
    let type = BookmarkType.locatorAudioBookTime.rawValue
    let version = 2
  }
  
  let type: BookmarkType
  var annotationId: String
  let locator: Any
  var lastSavedTimeStamp: String
  var isUnsynced: Bool {
    annotationId.isEmpty
  }
  
  enum CodingKeys: String, CodingKey {
    case type = "@type"
    case timeStamp
    case annotationId
    case locator
  }
  
  init(locator: LocatorAudioBookTime1, timeStamp: String = Date().iso8601, annotationId: String = "") {
    self.type = .locatorAudioBookTime
    self.lastSavedTimeStamp = timeStamp
    self.annotationId = annotationId
    self.locator = locator
  }
  
  init(locator: LocatorAudioBookTime2, timeStamp: String = Date().iso8601, annotationId: String = "") {
    self.type = .locatorAudioBookTime
    self.lastSavedTimeStamp = timeStamp
    self.annotationId = annotationId
    self.locator = locator
  }
  
  required public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = try container.decode(BookmarkType.self, forKey: .type)
    lastSavedTimeStamp = try container.decode(String.self, forKey: .timeStamp)
    annotationId = try container.decode(String.self, forKey: .annotationId)
    
    if type == .locatorAudioBookTime {
      if let locator = try? container.decode(LocatorAudioBookTime1.self, forKey: .locator) {
        self.locator = locator
      } else {
        self.locator = try container.decode(LocatorAudioBookTime2.self, forKey: .locator)
      }
    } else {
      throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unsupported bookmark type")
    }
  }
  
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(type.rawValue, forKey: .type)
    try container.encode(lastSavedTimeStamp, forKey: .timeStamp)
    try container.encode(annotationId, forKey: .annotationId)
    
    switch locator {
    case let locator as LocatorAudioBookTime1:
      try container.encode(locator, forKey: .locator)
    case let locator as LocatorAudioBookTime2:
      try container.encode(locator, forKey: .locator)
    default:
      throw EncodingError.invalidValue(locator, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unsupported locator type"))
    }
  }
  
  static func create(locatorData: [String: Any], timeStamp: String = Date().iso8601, annotationId: String = "") -> AudioBookmark? {
    guard let locatorDict = locatorData["locator"] as? [String: Any] else { return nil }
    
    if let data = try? JSONSerialization.data(withJSONObject: locatorDict, options: []),
       let locator = try? JSONDecoder().decode(LocatorAudioBookTime1.self, from: data) {
      return AudioBookmark(locator: locator, timeStamp: (locatorData["timeStamp"] as? String) ?? timeStamp, annotationId: (locatorData["annotationId"] as? String) ?? annotationId)
    }
    
    if let data = try? JSONSerialization.data(withJSONObject: locatorDict, options: []),
       let locator = try? JSONDecoder().decode(LocatorAudioBookTime2.self, from: data) {
      return AudioBookmark(locator: locator, timeStamp: (locatorData["timeStamp"] as? String) ?? timeStamp, annotationId: (locatorData["annotationId"] as? String) ?? annotationId)
    }
    
    return nil
  }
  
  public func toData() -> Data? {
    return try? JSONEncoder().encode(self)
  }
  
  public func isSimilar(to other: AudioBookmark) -> Bool {
    if self.type != other.type {
      return false
    }
    
    if let locator1 = self.locator as? LocatorAudioBookTime1,
       let locator2 = other.locator as? LocatorAudioBookTime1 {
      return locator1.title == locator2.title &&
      locator1.chapter == locator2.chapter &&
      locator1.part == locator2.part &&
      locator1.duration == locator2.duration &&
      locator1.startOffset == locator2.startOffset &&
      locator1.time == locator2.time &&
      locator1.audiobookID == locator2.audiobookID
    }
    
    if let locator1 = self.locator as? LocatorAudioBookTime2,
       let locator2 = other.locator as? LocatorAudioBookTime2 {
      return locator1.readingOrderItem == locator2.readingOrderItem &&
      locator1.readingOrderItemOffsetMilliseconds == locator2.readingOrderItemOffsetMilliseconds &&
      locator1.type == locator2.type &&
      locator1.version == locator2.version
    }
    
    return false
  }
  
  public func toTPPBookLocation() -> TPPBookLocation? {
    guard let data = try? JSONEncoder().encode(self),
          let locationString = String(data: data, encoding: .utf8) else {
      return nil
    }
    return TPPBookLocation(locationString: locationString, renderer: "PalaceAudiobookToolkit")
  }

  public func copy(with zone: NSZone? = nil) -> Any {
    let copy: AudioBookmark
    if let locator = locator as? LocatorAudioBookTime1 {
      copy = AudioBookmark(locator: locator, timeStamp: lastSavedTimeStamp, annotationId: annotationId)
    } else if let locator = locator as? LocatorAudioBookTime2 {
      copy = AudioBookmark(locator: locator, timeStamp: lastSavedTimeStamp, annotationId: annotationId)
    } else {
      fatalError("Unsupported locator type")
    }
    return copy
  }
}
