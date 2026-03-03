//
//  TPPReadiumBookmark+R3.swift
//  Palace
//
//  Created by Maurice Carrier on 11/19/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import ReadiumShared
import ReadiumNavigator

extension TPPReadiumBookmark {

  /// Converts the bookmark model into a location object that can be used
  /// with Readium 3.
  ///
  /// This conversion extracts essential data to represent the same location
  /// in the `Publication` using Readium 3's `Locator`.
  ///
  /// - Parameter publication: The Readium 3 `Publication` object where the bookmark is located.
  /// - Returns: A `Locator` object for Readium 3, or `nil` if conversion fails.
  func convertToR3(from publication: Publication) -> TPPBookmarkR3Location? {
    guard let href = AnyURL(string: self.href),
          let link = publication.linkWithHREF(href) else {
      return nil
    }

    let mediaType = link.mediaType ?? MediaType.xhtml

    let locations = Locator.Locations(
      progression: Double(progressWithinChapter),
      totalProgression: Double(progressWithinBook),
      position: Int(page ?? "0")
    )

    let locator = Locator(
      href: href,
      mediaType: mediaType,
      title: self.chapter,
      locations: locations,
      text: Locator.Text(highlight: nil)
    )

    guard let resourceIndex = publication.readingOrder.firstIndex(where: { $0.href == link.href }) else {
      return nil
    }

    let creationDate = NSDate(rfc3339String: self.time) as Date? ?? Date()

    return TPPBookmarkR3Location(resourceIndex: resourceIndex, locator: locator, creationDate: creationDate)
  }

  func locationMatches(_ locator: Locator) -> Bool {
    let locatorTotalProgress: Float?
    if let totalProgress = locator.locations.totalProgression {
      locatorTotalProgress = Float(totalProgress)
    } else {
      locatorTotalProgress = nil
    }

    let locatorChapterProgress: Float?
    if let chapterProgress = locator.locations.progression {
      locatorChapterProgress = Float(chapterProgress)
    } else {
      locatorChapterProgress = nil
    }

    return self.progressWithinChapter =~= locatorChapterProgress && self.progressWithinBook =~= locatorTotalProgress
  }
}
