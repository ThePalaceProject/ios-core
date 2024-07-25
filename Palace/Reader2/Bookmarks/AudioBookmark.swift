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
  var lastSavedTimeStamp: String?
  var version: Int
  var readingOrderItem: String?
  var readingOrderItemOffsetMilliseconds: UInt?
  // Other properties for older versions
  var chapter: String?
  var title: String?
  var part: Int?
  var time: Int?
  
  var isUnsynced: Bool {
    annotationId.isEmpty
  }
  
  enum CodingKeys: String, CodingKey {
    case type = "@type"
    case timeStamp
    case annotationId
    case version = "@version"
    case readingOrderItem
    case readingOrderItemOffsetMilliseconds
    case chapter
    case title
    case part
    case time
  }
  
  init(
    type: BookmarkType,
    version: Int = 2,
    timeStamp: String? = nil,
    annotationId: String = "",
    readingOrderItem: String? = nil,
    readingOrderItemOffsetMilliseconds: UInt? = nil,
    chapter: String? = nil,
    title: String? = nil,
    part: Int? = nil,
    time: Int? = nil
  ) {
    self.type = type
    self.lastSavedTimeStamp = timeStamp
    self.annotationId = annotationId
    self.version = version
    self.readingOrderItem = readingOrderItem
    self.readingOrderItemOffsetMilliseconds = readingOrderItemOffsetMilliseconds
    self.chapter = chapter
    self.title = title
    self.part = part
    self.time = time
  }
  
  required public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = try container.decode(BookmarkType.self, forKey: .type)
    lastSavedTimeStamp = try container.decodeIfPresent(String.self, forKey: .timeStamp)
    annotationId = try container.decodeIfPresent(String.self, forKey: .annotationId) ?? ""
    version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
    
    if type == .locatorAudioBookTime {
      if version == 2 {
        readingOrderItem = try container.decodeIfPresent(String.self, forKey: .readingOrderItem)
        readingOrderItemOffsetMilliseconds = try container.decodeIfPresent(UInt.self, forKey: .readingOrderItemOffsetMilliseconds)
      } else {
        readingOrderItem = try container.decodeIfPresent(String.self, forKey: .readingOrderItem)
        readingOrderItemOffsetMilliseconds = try container.decodeIfPresent(UInt.self, forKey: .time)
        chapter = try container.decodeIfPresent(String.self, forKey: .chapter)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        part = try container.decodeIfPresent(Int.self, forKey: .part)
      }
    } else {
      readingOrderItem = try container.decodeIfPresent(String.self, forKey: .readingOrderItem)
      readingOrderItemOffsetMilliseconds = try container.decodeIfPresent(UInt.self, forKey: .time)
      chapter = try container.decodeIfPresent(String.self, forKey: .chapter)
      title = try container.decodeIfPresent(String.self, forKey: .title)
      part = try container.decodeIfPresent(Int.self, forKey: .part)
    }
  }
  
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(type.rawValue, forKey: .type)
    try container.encode(lastSavedTimeStamp, forKey: .timeStamp)
    try container.encode(annotationId, forKey: .annotationId)
    try container.encode(version, forKey: .version)
    
    if version == 2 {
      try container.encodeIfPresent(readingOrderItem, forKey: .readingOrderItem)
      try container.encodeIfPresent(readingOrderItemOffsetMilliseconds, forKey: .readingOrderItemOffsetMilliseconds)
    } else {
      try container.encodeIfPresent(readingOrderItem, forKey: .readingOrderItem)
      try container.encodeIfPresent(readingOrderItemOffsetMilliseconds, forKey: .time)
      try container.encodeIfPresent(chapter, forKey: .chapter)
      try container.encodeIfPresent(title, forKey: .title)
      try container.encodeIfPresent(part, forKey: .part)
    }
  }
  
  static func create(locatorData: [String: Any], timeStamp: String? = Date().iso8601, annotationId: String = "") -> AudioBookmark? {
    guard let typeString = locatorData["@type"] as? String,
          let type = BookmarkType(rawValue: typeString) else { return nil }
    
    let version = locatorData["@version"] as? Int ?? 1
    let lastSavedTimeStamp = locatorData["timeStamp"] as? String ?? timeStamp
    let id = locatorData["annotationId"] as? String ?? annotationId
    
    if type == .locatorAudioBookTime {
      if version == 2 {
        return AudioBookmark(
          type: type,
          version: version,
          timeStamp: lastSavedTimeStamp,
          annotationId: id,
          readingOrderItem: locatorData["readingOrderItem"] as? String,
          readingOrderItemOffsetMilliseconds: locatorData["readingOrderItemOffsetMilliseconds"] as? UInt
        )
      } else {
        return AudioBookmark(
          type: type,
          version: version,
          timeStamp: timeStamp,
          annotationId: id,
          readingOrderItem: locatorData["readingOrderItem"] as? String,
          readingOrderItemOffsetMilliseconds: locatorData["readingOrderItemOffsetMilliseconds"] as? UInt,
          chapter: locatorData["chapter"] as? String,
          title: locatorData["title"] as? String,
          part: locatorData["part"] as? Int
        )
      }
    } else {
      return AudioBookmark(
        type: type,
        version: version,
        timeStamp: timeStamp,
        annotationId: id,
        readingOrderItem: locatorData["href"] as? String,
        readingOrderItemOffsetMilliseconds: locatorData["time"] as? UInt,
        chapter: locatorData["chapter"] as? String,
        title: locatorData["title"] as? String,
        part: locatorData["part"] as? Int
      )
    }
  }

  public func toData() -> Data? {
    let dict: [String: Any] = [
      "@type": type.rawValue,
      "@version": version,
      "timeStamp": lastSavedTimeStamp ?? "",
      "annotationId": annotationId,
      "readingOrderItem": readingOrderItem ?? "",
      "readingOrderItemOffsetMilliseconds": readingOrderItemOffsetMilliseconds ?? ""
    ]

    return try? JSONSerialization.data(withJSONObject: dict, options: [])
  }
  
  public func isSimilar(to other: AudioBookmark) -> Bool {
    if self.type != other.type {
      return false
    }
    
    return self.readingOrderItem == other.readingOrderItem &&
    self.readingOrderItemOffsetMilliseconds == other.readingOrderItemOffsetMilliseconds &&
    self.chapter == other.chapter &&
    self.title == other.title &&
    self.part == other.part &&
    self.time == other.time
  }
  
  public func toTPPBookLocation() -> TPPBookLocation? {
    guard let data = toData(),
          let locationString = String(data: data, encoding: .utf8) else {
      return nil
    }
    return TPPBookLocation(locationString: locationString, renderer: "PalaceAudiobookToolkit")
  }
  
  public func copy(with zone: NSZone? = nil) -> Any {
    return AudioBookmark(
      type: type,
      version: version,
      timeStamp: lastSavedTimeStamp,
      annotationId: annotationId,
      readingOrderItem: readingOrderItem,
      readingOrderItemOffsetMilliseconds: readingOrderItemOffsetMilliseconds,
      chapter: chapter,
      title: title,
      part: part,
      time: time
    )
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
    } else if let intVal = value as? Int {
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

extension Date {
  var iso8601: String {
    return ISO8601DateFormatter().string(from: self)
  }
}

extension AudioBookmark {
  var uniqueIdentifier: String {
    if let readingOrderItem, let readingOrderItemOffsetMilliseconds {
      return "\(readingOrderItem)-\(readingOrderItemOffsetMilliseconds)"
    } else if let chapter, let part, let time {
      return "\(chapter)-\(part)-\(time)"
    }
    return ""
  }
}
