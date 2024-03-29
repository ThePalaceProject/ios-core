//
//  TPPReadiumBookmark+R2.swift
//
//  Created by Ettore Pasquini on 4/23/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
import R2Shared

extension TPPReadiumBookmark {

  /// Converts the bookmark model into a location object that can be used
  /// with Readium 2.
  ///
  /// Not every single piece of data contained in this bookmark is considered
  /// for this conversion: only what's strictly necessary to be able to point
  /// at the same location inside the `Publication`.
  ///
  /// - Complexity: O(*n*) where *n* is the length of internal `Publication`
  /// data structures, such as list of chapters, resources, links.
  ///
  /// - Parameter publication: The R2 publication object where the bookmark is
  /// located.

  /// - Returns: An object with R2 location information pointing at the same
  /// position the bookmark model is pointing to.
  func convertToR2(from publication: Publication) -> TPPBookmarkR2Location? {
    guard let link = publication.link(withHREF: self.href) else {
      return nil
    }

    var position: Int? = nil
    if let page = page, let pos = Int(page) {
      position = pos
    }
    
    let locations = Locator.Locations(progression: Double(progressWithinChapter),
                                      totalProgression: Double(progressWithinBook),
                                      position: position)
    let locator = Locator(href: link.href,
                          type: publication.metadata.type ?? MediaType.xhtml.string,
                          title: self.chapter,
                          locations: locations)

    guard let resourceIndex = publication.readingOrder.firstIndex(withHREF: locator.href) else {
      return nil
    }

    let creationDate = NSDate(rfc3339String: self.time) as Date?
    return TPPBookmarkR2Location(resourceIndex: resourceIndex,
                                  locator: locator,
                                  creationDate: creationDate ?? Date())
  }

  /// Determines if a given locator matches the location addressed by this
  /// bookmark.
  ///
  /// This function converts a Readium 2 location into information compatible
  /// with the pre-existing Readium 1 data stored in TPPReadiumBookmark.
  /// This conversion should be lossless minus some Float epsilon error.
  ///
  /// - Complexity: O(*1*).
  ///
  /// - Parameters:
  ///   - locator: The object representing the given location in `publication`.
  ///   - locatorIDref: The ID reference of the resource the `locator` is
  ///   contained in.
  ///
  /// - Returns: `true` if the `locator`'s position matches the bookmark's.
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

