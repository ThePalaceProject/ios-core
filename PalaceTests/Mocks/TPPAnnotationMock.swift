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
  
  /// Storage for TPPReadiumBookmark objects (for EPUB bookmark testing)
  var readiumBookmarks: [String: [TPPReadiumBookmark]] = [:]
  
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
  
  func getServerBookmarks(forBook book: TPPBook?, atURL annotationURL: URL?, motivation: Palace.TPPBookmarkSpec.Motivation, completion: @escaping ([Palace.Bookmark]?) -> ()) {
    guard let bookID = book?.identifier else {
      completion([])
      return
    }
    
    // Return readiumBookmarks if they exist (for EPUB bookmark testing)
    if let storedReadiumBookmarks = readiumBookmarks[bookID], !storedReadiumBookmarks.isEmpty {
      completion(storedReadiumBookmarks)
      return
    }
    
    // Otherwise, fall back to audiobook bookmarks
    let bookmarks = motivation == .bookmark ? bookmarks[bookID] : savedLocations[bookID]
    completion(bookmarks?.compactMap {
      guard let selectorValueData = $0.value.data(using: String.Encoding.utf8) else {
        return nil
      }
      
      if let audiobookmark = try? JSONDecoder().decode(AudioBookmark.self, from: selectorValueData) {
        return audiobookmark
      } else {
        return nil
      }
    })
  }
  
  func deleteBookmark(annotationId: String, completionHandler: @escaping (Bool) -> ()) {
    // Delete from audiobook bookmarks
    for (bookId, bookmarksArray) in bookmarks {
      let filteredBookmarks = bookmarksArray.filter { $0.annotationId != annotationId }
      bookmarks[bookId] = filteredBookmarks
    }
    
    // Delete from readium bookmarks
    for (bookId, bookmarksArray) in readiumBookmarks {
      let filteredBookmarks = bookmarksArray.filter { $0.annotationId != annotationId }
      readiumBookmarks[bookId] = filteredBookmarks
    }
    
    completionHandler(true)
  }
  
  /// Deletes all bookmarks for a book from the mock server storage.
  /// This simulates fix: when a book is returned, all server bookmarks should be deleted.
  func deleteAllBookmarks(forBook book: TPPBook, completion: @escaping () -> Void) {
    let bookID = book.identifier
    
    // Delete all audiobook bookmarks for this book
    bookmarks[bookID] = []
    
    // Delete all readium bookmarks for this book
    readiumBookmarks[bookID] = []
    
    // Delete all saved locations for this book
    savedLocations[bookID] = []
    
    completion()
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
