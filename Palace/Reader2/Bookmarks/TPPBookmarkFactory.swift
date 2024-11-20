//
//  TPPBookmarkFactory.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 3/22/21.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

import Foundation
import ReadiumShared

class TPPBookmarkFactory {

  private let book: TPPBook
  private let publication: Publication
  private let drmDeviceID: String?

  init(book: TPPBook, publication: Publication, drmDeviceID: String?) {
    self.book = book
    self.publication = publication
    self.drmDeviceID = drmDeviceID
  }

  func make(fromR3Location bookmarkLoc: TPPBookmarkR3Location,
            usingBookRegistry bookRegistry: TPPBookRegistryProvider,
            for book: TPPBook,
            publication: Publication) -> TPPReadiumBookmark? {

    guard let chapterProgress = bookmarkLoc.locator.locations.progression.map(Float.init),
          let totalProgress = bookmarkLoc.locator.locations.totalProgression.map(Float.init) else {
      return nil
    }

    let page: String? = bookmarkLoc.locator.locations.position.map { "\($0)" }

    let href = bookmarkLoc.locator.href.string

    let chapter: String? = bookmarkLoc.locator.title
    ?? publication.tableOfContents.firstWithHREF(bookmarkLoc.locator.href)?.title

    let registryLocation = bookRegistry.location(forIdentifier: book.identifier)?.locationString

    return TPPReadiumBookmark(
      annotationId: nil,
      href: href,
      chapter: chapter,
      page: page,
      location: registryLocation,
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
    
    if book.isAudiobook,
       let selectorValueDict,
       let audioBookmark = AudioBookmark.create(
        locatorData: selectorValueDict,
        timeStamp: time,
        annotationId: annotationID
       ) {
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
