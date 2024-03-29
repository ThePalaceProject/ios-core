//
//  TPPAnnotationMock.swift
//  PalaceTests
//
//  Created by Maurice Carrier on 5/15/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
@testable import Palace

struct TestBookmark {
  var annotationId: String
  var value: String
}

extension TestBookmark {
  var toChapterLocation: ChapterLocation? {
    guard let selectorValueData = value.data(using: String.Encoding.utf8),
          let audioBookmark = try? JSONDecoder().decode(AudioBookmark.self, from: selectorValueData) else {
      return nil
    }
    return ChapterLocation(audioBookmark: audioBookmark)
  }
}

class TPPAnnotationMock: NSObject, AnnotationsManager {
  var savedLocations: [String: [TestBookmark]] = [:]
  var bookmarks: [String: [TestBookmark]] = [:]
  
  func postListeningPosition(forBook bookID: String, selectorValue: String, completion: ((String?) -> Void)?) {
    let annotationId = "TestAnnotationId\(bookID)"
    var array = savedLocations[bookID] ?? []
    array.append(TestBookmark(annotationId: annotationId, value: selectorValue))
    savedLocations[bookID] = array
    completion?(annotationId)
  }
  
  func postAudiobookBookmark(forBook bookID: String, selectorValue: String) async throws -> String? {
    let annotationId = "TestAnnotationId\(bookID)"
    bookmarks[bookID]?.append(TestBookmark(annotationId: annotationId, value: selectorValue))
    return annotationId
  }
  
  func getServerBookmarks(forBook bookID: String?, atURL annotationURL: URL?, motivation: Palace.TPPBookmarkSpec.Motivation, completion: @escaping ([Palace.Bookmark]?) -> ()) {
    guard let bookID = bookID else {
      completion([])
      return
    }

    let bookmarks = motivation == .bookmark ? bookmarks[bookID] : savedLocations[bookID]
    completion(bookmarks?.compactMap {
      guard let selectorValueData = $0.value.data(using: String.Encoding.utf8) else {
          return nil
      }

      if let audioBookmark = try? JSONDecoder().decode(AudioBookmark.self, from: selectorValueData) {
        audioBookmark.timeStamp = Date().iso8601
        audioBookmark.annotationId = "TestAnnotationId\(bookID)"
        return audioBookmark
      } else {
        return nil
      }
    })
  }

  func deleteBookmark(annotationId: String, completionHandler: @escaping (Bool) -> ()) {
    for (bookId, bookmarksArray) in bookmarks {
          let filteredBookmarks = bookmarksArray.filter { $0.annotationId != annotationId }
          bookmarks[bookId] = filteredBookmarks
        }

    completionHandler(true)
  }
}


