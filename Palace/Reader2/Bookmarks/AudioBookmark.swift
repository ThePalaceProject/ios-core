//
//  AudioBookmark.swift
//  Palace
//
//  Created by Maurice Carrier on 6/16/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

@objc class AudioBookmark: NSObject, Bookmark, Codable {
  let title: String
  let chapter: UInt
  let part: UInt
  let duration: UInt
  let startOffset: UInt
  let time: UInt
  let type: String
  let audiobookID: String
  var timeStamp: String = Date().iso8601
  var annotationId: String = ""

  enum CodingKeys: String, CodingKey {
    case title
    case chapter
    case part
    case duration
    case startOffset
    case time
    case type = "@type"
    case audiobookID
  }
}
