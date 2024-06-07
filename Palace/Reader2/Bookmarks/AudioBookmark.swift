//
//  AudioBookmark.swift
//  Palace
//
//  Created by Maurice Carrier on 6/16/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

enum BookmarkType: String, Codable {
  case locatorAudioBookTime = "LocatorAudioBookTime"
  case locatorHrefProgression = "LocatorHrefProgression"
}

@objc public class AudioBookmark: NSObject, Bookmark, Codable, NSCopying {
  let type: BookmarkType
  var annotationId: String
  let locator: [String: Any]
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
  
  init(locator: [String: Any], type: BookmarkType, timeStamp: String = Date().iso8601, annotationId: String = "") {
    self.type = type
    self.lastSavedTimeStamp = timeStamp
    self.annotationId = annotationId
    self.locator = locator
  }
  
  required public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = try container.decode(BookmarkType.self, forKey: .type)
    lastSavedTimeStamp = try container.decodeIfPresent(String.self, forKey: .timeStamp) ?? Date().iso8601
    annotationId = try container.decodeIfPresent(String.self, forKey: .annotationId) ?? ""
    locator = try container.decode([String: AnyCodable].self, forKey: .locator).mapValues { $0.value }
  }
  
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(type.rawValue, forKey: .type)
    try container.encode(lastSavedTimeStamp, forKey: .timeStamp)
    try container.encode(annotationId, forKey: .annotationId)
    try container.encode(locator.mapValues { AnyCodable($0) }, forKey: .locator)
  }
  
  static func create(locatorData: [String: Any], timeStamp: String = Date().iso8601, annotationId: String = "") -> AudioBookmark? {
    guard let typeString = locatorData["@type"] as? String,
            let type = BookmarkType(rawValue: typeString) else { return nil }
    
    let locatorDict = locatorData.filter({ $0.key != "@type" && $0.key != "@version" }) as [String: Any]
    
    return AudioBookmark(locator: locatorDict, type: type, timeStamp: (locatorData["timeStamp"] as? String) ?? timeStamp, annotationId: (locatorData["annotationId"] as? String) ?? annotationId)
  }
  
  public func toData() -> Data? {
    return try? JSONEncoder().encode(self)
  }
  
  public func isSimilar(to other: AudioBookmark) -> Bool {
    if self.type != other.type {
      return false
    }
    
    return NSDictionary(dictionary: self.locator).isEqual(to: other.locator)
  }
  
  public func toTPPBookLocation() -> TPPBookLocation? {
    guard let data = try? JSONEncoder().encode(self),
          let locationString = String(data: data, encoding: .utf8) else {
      return nil
    }
    return TPPBookLocation(locationString: locationString, renderer: "PalaceAudiobookToolkit")
  }
  
  public func copy(with zone: NSZone? = nil) -> Any {
    return AudioBookmark(locator: locator, type: type, timeStamp: lastSavedTimeStamp, annotationId: annotationId)
  }
}

struct AnyCodable: Codable {
  var value: Any
  
  init(_ value: Any) {
    self.value = value
  }
  
  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let intVal = try? container.decode(Int.self) {
      value = intVal
    } else if let doubleVal = try? container.decode(Double.self) {
      value = doubleVal
    } else if let boolVal = try? container.decode(Bool.self) {
      value = boolVal
    } else if let stringVal = try? container.decode(String.self) {
      value = stringVal
    } else if let nestedVal = try? container.decode([String: AnyCodable].self) {
      value = Dictionary(uniqueKeysWithValues: nestedVal.map { key, value in (key, value.value) })
    } else if let arrayVal = try? container.decode([AnyCodable].self) {
      value = arrayVal.map { $0.value }
    } else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    if let intVal = value as? UInt {
      try container.encode(intVal)
    }  else if let intVal = value as? Int {
      try container.encode(intVal)
    } else if let doubleVal = value as? Double {
      try container.encode(doubleVal)
    } else if let floatValue = value as? Float {
      try container.encode(floatValue)
    } else if let boolVal = value as? Bool {
      try container.encode(boolVal)
    } else if let stringVal = value as? String {
      try container.encode(stringVal)
    } else if let nestedVal = value as? [String: Any] {
      try container.encode(nestedVal.mapValues { AnyCodable($0) })
    } else if let arrayVal = value as? [Any] {
      try container.encode(arrayVal.map { AnyCodable($0) })
    } else {
      throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unsupported type"))
    }
  }
}

// Utility to get ISO8601 formatted date string
extension Date {
  var iso8601: String {
    return ISO8601DateFormatter().string(from: self)
  }
}


extension AudioBookmark {
  struct LocatorHrefProgression: Codable {
    let chapter: String
    let cssSelector: String
    let href: String
    let part: Int
    let position: Int
    let progressWithinBook: Double
    let progressWithinChapter: Double
    let time: Int
    let title: String
    
    enum CodingKeys: String, CodingKey {
      case chapter
      case cssSelector
      case href
      case part
      case position
      case progressWithinBook
      case progressWithinChapter
      case time
      case title
      case type = "@type"
    }
    
    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      chapter = try container.decodeIfPresent(String.self, forKey: .chapter) ?? ""
      cssSelector = try container.decodeIfPresent(String.self, forKey: .cssSelector) ?? ""
      href = try container.decodeIfPresent(String.self, forKey: .href) ?? ""
      part = try container.decodeIfPresent(Int.self, forKey: .part) ?? 0
      position = try container.decodeIfPresent(Int.self, forKey: .position) ?? 0
      progressWithinBook = try container.decodeIfPresent(Double.self, forKey: .progressWithinBook) ?? 0.0
      progressWithinChapter = try container.decodeIfPresent(Double.self, forKey: .progressWithinChapter) ?? 0.0
      time = try container.decodeIfPresent(Int.self, forKey: .time) ?? 0
      title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
      _ = try container.decode(String.self, forKey: .type) // Consume the "@type" field
    }
    
    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(chapter, forKey: .chapter)
      try container.encode(cssSelector, forKey: .cssSelector)
      try container.encode(href, forKey: .href)
      try container.encode(part, forKey: .part)
      try container.encode(position, forKey: .position)
      try container.encode(progressWithinBook, forKey: .progressWithinBook)
      try container.encode(progressWithinChapter, forKey: .progressWithinChapter)
      try container.encode(time, forKey: .time)
      try container.encode(title, forKey: .title)
      try container.encode("LocatorHrefProgression", forKey: .type)
    }
  }
  
  struct LocatorAudioBookTime: Codable {
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
}
