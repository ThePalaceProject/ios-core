//
//  AudioBookmark.swift
//  Palace
//
//  Created by Maurice Carrier on 6/16/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

@objc class AudioBookmark: NSObject, Bookmark, Codable {
  let audiobookID: String
  let title: String
  let part: UInt
  let duration: Double
  let startOffset: Double
  let number: UInt
  let playheadOffset: Double
}
