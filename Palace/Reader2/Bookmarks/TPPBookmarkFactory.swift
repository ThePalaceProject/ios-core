//
//  TPPBookmarkFactory.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 3/22/21.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

import Foundation
import R2Shared

class TPPBookmarkFactory {

  private let book: TPPBook
  private let publication: Publication
  private let drmDeviceID: String?

  init(book: TPPBook, publication: Publication, drmDeviceID: String?) {
    self.book = book
    self.publication = publication
    self.drmDeviceID = drmDeviceID
  }

  func make(fromR2Location bookmarkLoc: TPPBookmarkR2Location,
            usingBookRegistry bookRegistry: TPPBookRegistryProvider) -> TPPReadiumBookmark? {

    guard let progression = bookmarkLoc.locator.locations.progression else {
      return nil
    }
    let chapterProgress = Float(progression)

    guard let total = bookmarkLoc.locator.locations.totalProgression else {
      return nil
    }
    let totalProgress = Float(total)

    var page: String? = nil
    if let position = bookmarkLoc.locator.locations.position {
      page = "\(position)"
    }

    let registryLoc = bookRegistry.location(forIdentifier: book.identifier)
    var href: String? = nil

    href = bookmarkLoc.locator.href

    let chapter: String?
    if let locatorChapter = bookmarkLoc.locator.title {
      chapter = locatorChapter
    } else if let tocLink = publication.tableOfContents.first(withHREF: bookmarkLoc.locator.href) {
      chapter = tocLink.title
    } else {
      chapter = nil
    }

    return TPPReadiumBookmark(
      annotationId: nil,
      href: href,
      chapter: chapter,
      page: page,
      location: registryLoc?.locationString,
      progressWithinChapter: chapterProgress,
      progressWithinBook: totalProgress,
      readingOrderItem: nil,
      readingOrderItemOffsetMilliseconds: 0.0,
      time: (bookmarkLoc.creationDate as NSDate).rfc3339String(),
      device: drmDeviceID
    )
  }

  class func make(fromServerAnnotation annotation: [String: Any],
                  annotationType: TPPBookmarkSpec.Motivation,
                  book: TPPBook) -> Bookmark? {

    let bookID = book.identifier
    
    guard let annotationID = annotation[TPPBookmarkSpec.Id.key] as? String else {
      Log.error(#file, "Missing AnnotationID:\(annotation)")
      return nil
    }

    guard let target = annotation[TPPBookmarkSpec.Target.key] as? [String: AnyObject],
      let source = target[TPPBookmarkSpec.Target.Source.key] as? String,
      let motivation = annotation[TPPBookmarkSpec.Motivation.key] as? String else {
        Log.error(#file, "Error parsing required key/values for target.")
        return nil
    }

     guard source == bookID else {
       TPPErrorLogger.logError(withCode: .bookmarkReadError,
                                summary: "Got bookmark for a different book",
                                metadata: [
                                 "requestedBookID": bookID,
                                 "serverAnnotation": annotation])
       return nil
     }

    guard motivation == annotationType.rawValue else {
      return nil
    }

    guard
      let body = annotation[TPPBookmarkSpec.Body.key] as? [String: AnyObject],
      let device = body[TPPBookmarkSpec.Body.Device.key] as? String,
      let time = body[TPPBookmarkSpec.Body.Time.key] as? String
      else {
        Log.error(#file, "Error reading required bookmark key/values from body")
        return nil
    }

    guard
      let selector = target[TPPBookmarkSpec.Target.Selector.key] as? [String: AnyObject],
      let selectorValueEscJSON = selector[TPPBookmarkSpec.Target.Selector.Value.key] as? String
      else {
        Log.error(#file, "Error reading required Selector Value from Target.")
        return nil
    }

    guard let selectorValueData = selectorValueEscJSON.data(using: String.Encoding.utf8),
    let selectorValueDict = try? JSONSerialization.jsonObject(with: selectorValueData, options: []) as? [String: Any]
    else {
      Log.error(#file, "Error serializing serverCFI into JSON. Selector.Value=\(selectorValueEscJSON)")
        return nil
    }
    
    if book.isAudiobook, let selectorValueDict, let audioBookmark = AudioBookmark.create(locatorData: selectorValueDict, timeStamp: time, annotationId: annotationID) {
      return audioBookmark
    }
    
    if let pdfPageBookmark = try? JSONDecoder().decode(TPPPDFPageBookmark.self, from: selectorValueData),
        pdfPageBookmark.type == TPPPDFPageBookmark.Types.locatorPage.rawValue {
      pdfPageBookmark.annotationID = annotationID
      return pdfPageBookmark
    }
  
    guard let selectorValueJSON = (try? JSONSerialization.jsonObject(with: selectorValueData, options: [])) as? [String: Any] else {
      Log.error(#file, "Error serializing serverCFI into JSON. Selector.Value=\(selectorValueEscJSON)")
      return nil
    }
  
      let href = selectorValueJSON["href"] as? String ?? ""
      let chapter = body[TPPBookmarkSpec.Body.ChapterTitle.key] as? String ?? selectorValueJSON["title"] as? String
      let progressWithinChapter = selectorValueJSON["progressWithinChapter"] as? Float
      let progressWithinBook = Float(selectorValueJSON["progressWithinBook"] as? Double ?? body[TPPBookmarkSpec.Body.ProgressWithinBook.key] as? Double ?? 0.0)
      let readingOrderItem = selectorValueJSON["readingOrderItem"] as? String
      let readingOrderItemOffsetMilliseconds = selectorValueJSON["readingOrderItemOffsetMilliseconds"] as? Float

      return TPPReadiumBookmark(
        annotationId: annotationID,
        href: href,
        chapter: chapter,
        page: nil,
        location: selectorValueEscJSON,
        progressWithinChapter: progressWithinChapter ?? 0.0,
        progressWithinBook: progressWithinBook,
        readingOrderItem: readingOrderItem,
        readingOrderItemOffsetMilliseconds: readingOrderItemOffsetMilliseconds,
        time:time,
        device:device
      )
  }
}
