//
//  TPPAnnotationMock.swift
//  PalaceTests
//
//  Created by Maurice Carrier on 5/15/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
@testable import Palace
@testable import PalaceAudiobookToolkit

import Foundation
@testable import Palace
@testable import PalaceAudiobookToolkit

struct TestBookmark {
  var annotationId: String
  var value: String
}

class TPPAnnotationMock: NSObject, AnnotationsManager {
  var savedLocations: [String: [TestBookmark]] = [:]
  var bookmarks: [String: [TestBookmark]] = [:]
  
  var syncIsPossibleAndPermitted: Bool { true }
  
  func postListeningPosition(forBook bookID: String, selectorValue: String, completion: ((AnnotationResponse?) -> Void)?) {
    let annotationId = "\(generateRandomString(length: 8))\(bookID)"
    var array = savedLocations[bookID] ?? []
    array.append(TestBookmark(annotationId: annotationId, value: selectorValue))
    savedLocations[bookID] = array
    let response = AnnotationResponse(serverId: annotationId, timeStamp: Date().ISO8601Format())
    completion?(response)
  }
  
  func postAudiobookBookmark(forBook bookID: String, selectorValue: String) async throws -> AnnotationResponse? {
    let annotationId = "\(generateRandomString(length: 8))\(bookID)"
    bookmarks[bookID]?.append(TestBookmark(annotationId: annotationId, value: selectorValue))
    let response = AnnotationResponse(serverId: annotationId, timeStamp: Date().ISO8601Format())
    return response
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
      
      if let audiobookmark = try? JSONDecoder().decode(AudioBookmark.self, from: selectorValueData) {
        audiobookmark.lastSavedTimeStamp = Date().ISO8601Format()
        return audiobookmark
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
  
  func generateRandomString(length: Int) -> String {
    let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    var randomString = ""
    
    for _ in 0..<length {
      let randomIndex = Int(arc4random_uniform(UInt32(letters.count)))
      let randomCharacter = letters[letters.index(letters.startIndex, offsetBy: randomIndex)]
      randomString.append(randomCharacter)
    }
    
    return randomString
  }
}
