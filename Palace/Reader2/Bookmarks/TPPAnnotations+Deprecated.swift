//
//  TPPAnnotations+Deprecated.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 3/24/21.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

import Foundation

/// - Important: all these functions are deprecated. Do not use in new code.
extension TPPAnnotations {
  /// Important: this is deprecated. Do not use in new code.
  class func postR1Bookmark(_ bookmark: TPPReadiumBookmark,
                            forBookID bookID: String,
                            completion: @escaping (_ serverID: String?) -> ())
  {
    guard syncIsPossibleAndPermitted() else {
      Log.debug(#file, "Account does not support sync or sync is disabled.")
      completion(nil)
      return
    }

    guard let annotationsURL = TPPAnnotations.annotationsURL else {
      Log.error(#file, "Annotations URL was nil while posting R1 bookmark")
      return
    }

    let parameters = [
      TPPBookmarkSpec.Context.key: TPPBookmarkSpec.Context.value,
      TPPBookmarkSpec.type.key: TPPBookmarkSpec.type.value,
      TPPBookmarkSpec.Motivation.key: TPPBookmarkSpec.Motivation.bookmark.rawValue,
      TPPBookmarkSpec.Target.key: [
        TPPBookmarkSpec.Target.Source.key: bookID,
        TPPBookmarkSpec.Target.Selector.key: [
          TPPBookmarkSpec.Target.Selector.type.key: TPPBookmarkSpec.Target.Selector.type.value,
          TPPBookmarkSpec.Target.Selector.Value.key: bookmark.location
        ]
      ],
      TPPBookmarkSpec.Body.key: [
        TPPBookmarkSpec.Body.Time.key : bookmark.time,
        TPPBookmarkSpec.Body.Device.key : bookmark.device ?? "",
        "http://librarysimplified.org/terms/chapter" : bookmark.chapter ?? "",
        "http://librarysimplified.org/terms/progressWithinChapter" : bookmark.progressWithinChapter,
        "http://librarysimplified.org/terms/progressWithinBook" : bookmark.progressWithinBook,
      ]
      ] as [String : Any]

    postAnnotation(forBook: bookID, withAnnotationURL: annotationsURL, withParameters: parameters, queueOffline: false) { (success, id) in
      completion(id)
    }
  }
  
  class func postR2Bookmark(_ bookmark: TPPReadiumBookmark,
                            forBookID bookID: String,
                            completion: @escaping (_ serverID: String?) -> ())
  {
    guard syncIsPossibleAndPermitted() else {
      Log.debug(#file, "Account does not support sync or sync is disabled.")
      completion(nil)
      return
    }
    
    guard let annotationsURL = TPPAnnotations.annotationsURL else {
      Log.error(#file, "Annotations URL was nil while posting R1 bookmark")
      return
    }
    
    let spec = TPPBookmarkSpec(id: UUID().uuidString, time: (bookmark.time.dateFromISO8601 as NSDate? ?? NSDate()), device: bookmark.device ?? "", motivation: .bookmark, bookID: bookID, selectorValue: bookmark.location)
    let parameters = spec.dictionaryForJSONSerialization()

    postAnnotation(forBook: bookID, withAnnotationURL: annotationsURL, withParameters: parameters, queueOffline: false) { (success, id) in
      completion(id)
    }
  }
}
