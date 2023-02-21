//
//  TPPBookLocation+Locator.swift
//  The Palace Project
//
//  Created by Ernest Fan on 2020-11-09.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
import R2Shared

extension TPPBookLocation {
  static let r2Renderer = "readium2"
  
  convenience init?(locator: Locator,
                    type: String,
                    publication: Publication,
                    renderer: String = TPPBookLocation.r2Renderer) {
    // Store all required properties of a locator object in a dictionary
    // Create a json string from it and use it as the location string in NYPLBookLocation
    // There is no specific format to follow, the value of the keys can be change if needed
    let dict: [String : Any] = [
      TPPBookLocation.hrefKey: locator.href,
      TPPBookLocation.typeKey: type,
      TPPBookLocation.chapterProgressKey: locator.locations.progression ?? 0.0,
      TPPBookLocation.bookProgressKey: locator.locations.totalProgression ?? 0.0,
      TPPBookLocation.titleKey: locator.title ?? "",
      TPPBookLocation.positionKey: locator.locations.position ?? 0.0
    ]
    
    guard let jsonString = serializeJSONString(dict) else {
      Log.warn(#file, "Failed to serialize json string from dictionary - \(dict.debugDescription)")
      return nil
    }
    
    self.init(locationString: jsonString, renderer: renderer)
  }
  
  convenience init?(href: String,
                    type: String,
                    time: Double? = nil,
                    part: Float? = nil,
                    chapter: String? = nil,
                    chapterProgression: Float? = nil,
                    totalProgression: Float? = nil,
                    title: String? = nil,
                    position: Float? = nil,
                    publication: Publication? = nil,
                    renderer: String = TPPBookLocation.r2Renderer) {
    
    // Store all required properties of a locator object in a dictionary
    // Create a json string from it and use it as the location string in NYPLBookLocation
    // There is no specific format to follow, the value of the keys can be change if needed
    let dict: [String : Any] = [
      TPPBookLocation.hrefKey: href,
      TPPBookLocation.typeKey: type,
      TPPBookLocation.timeKey: time ?? 0.0,
      TPPBookLocation.partKey: part ?? 0.0,
      TPPBookLocation.chapterKey: chapter ?? "",
      TPPBookLocation.chapterProgressKey: chapterProgression ?? 0.0,
      TPPBookLocation.bookProgressKey: totalProgression ?? 0.0,
      TPPBookLocation.titleKey: title ?? "",
      TPPBookLocation.positionKey: position ?? 0.0
    ]
    
    guard let jsonString = serializeJSONString(dict) else {
      Log.warn(#file, "Failed to serialize json string from dictionary - \(dict.debugDescription)")
      return nil
    }
    
    self.init(locationString: jsonString, renderer: renderer)
  }
  
  func convertToLocator() -> Locator? {
    guard self.renderer == TPPBookLocation.r2Renderer,
      let data = self.locationString.data(using: .utf8),
      let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
      let href = dict[TPPBookLocation.hrefKey] as? String,
      let type = dict[TPPBookLocation.typeKey] as? String,
      let progressWithinChapter = dict[TPPBookLocation.chapterProgressKey] as? Double,
      let progressWithinBook = dict[TPPBookLocation.bookProgressKey] as? Double else {
      Log.error(#file, "Failed to convert NYPLBookLocation to Locator object with location string: \(locationString ?? "N/A")")
      return nil
    }

    let title: String = dict[TPPBookLocation.titleKey] as? String ?? ""
    let position: Int? = dict[TPPBookLocation.positionKey] as? Int

    let locations = Locator.Locations(fragments: [],
                                      progression: progressWithinChapter,
                                      totalProgression: progressWithinBook,
                                      position: position,
                                      otherLocations: [:])
    
    return Locator(href: href,
                   type: type,
                   title: title,
                   locations: locations)
  }
}

private extension TPPBookLocation {
  static let hrefKey = "href"
  static let typeKey = "@type"
  static let chapterProgressKey = "progressWithinChapter"
  static let bookProgressKey = "progressWithinBook"
  static let titleKey = "title"
  static let timeKey = "time"
  static let partKey = "part"
  static let chapterKey = "chapter"
  static let positionKey = "position"
}
