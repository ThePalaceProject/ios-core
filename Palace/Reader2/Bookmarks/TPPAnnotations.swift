import UIKit
import ReadiumShared

public struct AnnotationResponse {
  var serverId: String?
  var timeStamp: String?
}

protocol AnnotationsManager {
  var syncIsPossibleAndPermitted: Bool { get }
  func postListeningPosition(forBook bookID: String, selectorValue: String, completion: ((_ response: AnnotationResponse?) -> Void)?)
  func postAudiobookBookmark(forBook bookID: String, selectorValue: String) async throws -> AnnotationResponse?
  func getServerBookmarks(forBook book: TPPBook?,
                                atURL annotationURL:URL?,
                                motivation: TPPBookmarkSpec.Motivation,
                                completion: @escaping (_ bookmarks: [Bookmark]?) -> ())
  func deleteBookmark(annotationId: String, completionHandler: @escaping (_ success: Bool) -> ())
}

@objcMembers final class TPPAnnotationsWrapper: NSObject, AnnotationsManager {
  var syncIsPossibleAndPermitted: Bool { TPPAnnotations.syncIsPossibleAndPermitted() }

  func postListeningPosition(forBook bookID: String, selectorValue: String, completion: ((_ response: AnnotationResponse?) -> Void)?) {
    TPPAnnotations.postListeningPosition(forBook: bookID, selectorValue: selectorValue, completion: completion)
  }
  
  func postAudiobookBookmark(forBook bookID: String, selectorValue: String) async throws -> AnnotationResponse? {
    try await TPPAnnotations.postAudiobookBookmark(forBook: bookID, selectorValue: selectorValue)
  }
  
  func getServerBookmarks(forBook book: TPPBook?, atURL annotationURL: URL?, motivation: TPPBookmarkSpec.Motivation = .bookmark, completion: @escaping ([Bookmark]?) -> ()) {
    TPPAnnotations.getServerBookmarks(forBook: book, atURL: annotationURL, motivation: motivation, completion: completion)
  }
  
  func deleteBookmark(annotationId: String, completionHandler: @escaping (Bool) -> ()) {
    TPPAnnotations.deleteBookmark(annotationId: annotationId, completionHandler: completionHandler)
  }
}

@objcMembers final class TPPAnnotations: NSObject {
  // MARK: - Reading Position

  /// Asynchronously syncs the reading position of a book.
  /// - Parameters:
  ///   - book: The `TPPBook` whose reading position is being synced.
  ///   - url: The server URL for syncing the reading position.
  /// - Returns: The most recent reading position (`Bookmark?`) from the server.
  class func syncReadingPosition(ofBook book: TPPBook?, toURL url: URL?) async -> Bookmark? {
    guard syncIsPossibleAndPermitted() else {
      Log.debug(#file, "Account does not support sync or sync is disabled.")
      return nil
    }

    let bookmarks = await withCheckedContinuation { continuation in
      var didResume = false

      getServerBookmarks(forBook: book, atURL: url, motivation: .readingProgress) { bookmarks in
        guard !didResume else { return }
        didResume = true

        continuation.resume(returning: bookmarks)
      }
    }

    return bookmarks?.first
  }

  class func postListeningPosition(forBook bookID: String, selectorValue: String, completion: ((_ response: AnnotationResponse?) -> Void)? = nil) {
    postReadingPosition(forBook: bookID, selectorValue: selectorValue, motivation:  .readingProgress, completion: completion)
  }

  class func postAudiobookBookmark(forBook bookID: String, selectorValue: String) async throws -> AnnotationResponse? {
    return try await withCheckedThrowingContinuation { continuation in
      postReadingPosition(forBook: bookID, selectorValue: selectorValue, motivation: .bookmark) { response in
        if let response {
          continuation.resume(returning: response)
        } else {
          continuation.resume(throwing: NSError(domain: "Error posting bookmark", code: 1, userInfo: nil))
        }
      }
    }
  }

  class func postReadingPosition(forBook bookID: String, selectorValue: String, motivation: TPPBookmarkSpec.Motivation, completion: ((_ response: AnnotationResponse?) -> Void)? = nil) {
    guard syncIsPossibleAndPermitted() else {
      Log.debug(#file, "Account does not support sync or sync is disabled.")
      completion?(nil)
      return
    }

    guard let annotationsURL = TPPAnnotations.annotationsURL else {
      Log.error(#file, "Annotations URL was nil while updating reading position")
      completion?(nil)
      return
    }

    // Format bookmark for submission to server according to spec
    let bookmark = TPPBookmarkSpec(time: NSDate(),
                                    device: TPPUserAccount.sharedAccount().deviceID ?? "",
                                    motivation: motivation,
                                    bookID: bookID,
                                    selectorValue: selectorValue)
    let parameters = bookmark.dictionaryForJSONSerialization()

    postAnnotation(forBook: bookID, withAnnotationURL: annotationsURL, withParameters: parameters, queueOffline: true) { (success, id, timeStamp) in
      guard success else {
        TPPErrorLogger.logError(withCode: .apiCall,
                                 summary: "Error posting annotation",
                                 metadata: [
                                  "bookID": bookID,
                                  "annotationID": id ?? "N/A",
                                  "annotationURL": annotationsURL])
        completion?(nil)
        return
      }

      Log.debug(#file, "Successfully saved Reading Position to server: \(selectorValue)")
      completion?(AnnotationResponse(serverId: id, timeStamp: timeStamp))
    }
  }
  
  class func postBookmark(_ page: TPPPDFPage, annotationsURL: URL?, forBookID bookID: String, completion: @escaping (_ annotationResponse: AnnotationResponse?) -> Void) {
    guard syncIsPossibleAndPermitted() else {
      Log.debug(#file, "Account does not support sync or sync is disabled.")
      completion(nil)
      return
    }

    guard let annotationsURL = annotationsURL ?? TPPAnnotations.annotationsURL else {
      Log.error(#file, "Annotations URL was nil while posting bookmark")
      return
    }

    guard let selectorValue = page.bookmarkSelector else {
      Log.error(#file, "Bookmark selectorValue was nil while posting bookmark")
      return
    }
    
    let spec = TPPBookmarkSpec(
      time: NSDate(),
      device: TPPUserAccount.sharedAccount().deviceID ?? "",
      motivation: .bookmark,
      bookID: bookID,
      selectorValue: selectorValue
    )

    let parameters = spec.dictionaryForJSONSerialization()

    postAnnotation(forBook: bookID, withAnnotationURL: annotationsURL, withParameters: parameters, queueOffline: false) { (success, id, timeStamp) in
      completion(AnnotationResponse(serverId: id, timeStamp: timeStamp))
    }
  }
  
  class func postBookmark(_ bookmark: TPPReadiumBookmark,
                            forBookID bookID: String,
                          completion: @escaping (_ annotationResponse: AnnotationResponse?) -> ())
  {
    guard syncIsPossibleAndPermitted() else {
      Log.debug(#file, "Account does not support sync or sync is disabled.")
      completion(nil)
      return
    }

    guard let annotationsURL = TPPAnnotations.annotationsURL else {
      Log.error(#file, "Annotations URL was nil while posting bookmark")
      return
    }

    let spec = TPPBookmarkSpec(
      id: UUID().uuidString,
      time: (bookmark.time.dateFromISO8601 as NSDate? ?? NSDate()),
      device: bookmark.device ?? "",
      motivation: .bookmark,
      bookID: bookID,
      selectorValue: bookmark.location
    )

    let parameters = spec.dictionaryForJSONSerialization()

    postAnnotation(forBook: bookID, withAnnotationURL: annotationsURL, withParameters: parameters, queueOffline: false) { (success, id, timeStamp) in
      completion(AnnotationResponse(serverId: id, timeStamp: timeStamp))
    }
  }

  /// Serializes the `parameters` into JSON and POSTs them to the server.
  class func postAnnotation(forBook bookID: String,
                            withAnnotationURL url: URL,
                            withParameters parameters: [String: Any],
                            timeout: TimeInterval = TPPDefaultRequestTimeout,
                            queueOffline: Bool,
                            _ completionHandler: @escaping (_ success: Bool, _ annotationID: String?, _ timeStamp: String?) -> ()) {

    guard let jsonData = try? JSONSerialization.data(withJSONObject: parameters, options: [.prettyPrinted]) else {
      Log.error(#file, "Network request abandoned. Could not create JSON from given parameters.")
      completionHandler(false, nil, nil)
      return
    }

    var request = TPPNetworkExecutor.shared.request(for: url)
    request.httpMethod = "POST"
    request.httpBody = jsonData
    request.timeoutInterval = timeout

    let task = TPPNetworkExecutor.shared.POST(request, useTokenIfAvailable: true) { (data, response, error) in
      if let error = error as NSError? {
        Log.error(#file, "Annotation POST error (nsCode: \(error.code) Description: \(error.localizedDescription))")
        if (NetworkQueue.StatusCodes.contains(error.code)) && (queueOffline == true) {
          self.addToOfflineQueue(bookID, url, parameters)
        }
        completionHandler(false, nil, nil)
        return
      }
      guard let statusCode = (response as? HTTPURLResponse)?.statusCode else {
        Log.error(#file, "Annotation POST error: No response received from server")
        completionHandler(false, nil, nil)
        return
      }

      if statusCode == 200 {
        Log.debug(#file, "Annotation POST: Success 200.")
        let serverAnnotationID = annotationID(fromNetworkData: data)
        let timeStamp = timeStamp(fromNetworkData: data)
        completionHandler(true, serverAnnotationID, timeStamp)
      } else {
        Log.error(#file, "Annotation POST: Response Error. Status Code: \(statusCode)")
        completionHandler(false, nil, nil)
      }
    }
    task?.resume()
  }

  private class func annotationID(fromNetworkData data: Data?) -> String? {
    guard let data = data else {
      Log.error(#file, "No Annotation ID saved: No data received from server.")
      return nil
    }
    guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String:Any] else {
      Log.error(#file, "No Annotation ID saved: JSON could not be created from data.")
      return nil
    }
    if let annotationID = json[TPPBookmarkSpec.Id.key] as? String {
      return annotationID
    } else {
      Log.error(#file, "No Annotation ID saved: Key/Value not found in JSON response.")
      return nil
    }
  }
  
  private class func timeStamp(fromNetworkData data: Data?) -> String? {
    guard let data = data else {
      Log.error(#file, "No Annotation ID saved: No data received from server.")
      return nil
    }
    guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String:Any] else {
      Log.error(#file, "No Annotation ID saved: JSON could not be created from data.")
      return nil
    }
    if let body = json[TPPBookmarkSpec.Body.key] as? [String:Any], let timeStamp = body[TPPBookmarkSpec.Body.Time.key] as? String {
      return timeStamp
    } else {
      Log.error(#file, "No Annotation ID saved: Key/Value not found in JSON response.")
      return nil
    }
  }

  // MARK: - Bookmarks

  // Completion handler will return a nil parameter if there are any failures with
  // the network request, deserialization, or sync permission is not allowed.
  class func getServerBookmarks(forBook book:TPPBook?,
                                atURL annotationURL:URL?,
                                motivation: TPPBookmarkSpec.Motivation = .bookmark,
                                completion: @escaping (_ bookmarks: [Bookmark]?) -> ()) {

    guard syncIsPossibleAndPermitted() else {
      Log.debug(#file, "Account does not support sync or sync is disabled.")
      completion(nil)
      return
    }

    guard let book, let annotationURL else {
      Log.error(#file, "Required parameter was nil.")
      completion(nil)
      return
    }
    
    let dataTask = TPPNetworkExecutor.shared.GET(annotationURL, useTokenIfAvailable: true) { (data, response, error) in
      
      if let error = error as NSError? {
        Log.error(#file, "Request Error Code: \(error.code). Description: \(error.localizedDescription)")
        completion(nil)
        return
      }

      guard let data,
        let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
        let json = jsonObject as? [String: Any] else {
          Log.error(#file, "Response from annotation server could not be serialized.")
          completion(nil)
          return
      }

      guard let first = json["first"] as? [String: Any],
        let items = first["items"] as? [[String: Any]] else {
          Log.error(#file, "Missing required key from Annotations response, or no items exist.")
          completion(nil)
          return
      }

      let bookmarks = items.compactMap {
        TPPBookmarkFactory.make(fromServerAnnotation: $0,
                                 annotationType: motivation,
                                 book: book)
      }

      completion(bookmarks)
    }

    dataTask?.resume()
  }

  class func deleteBookmarks(_ bookmarks: [TPPReadiumBookmark]) {

    for localBookmark in bookmarks {
      if let annotationID = localBookmark.annotationId {
        deleteBookmark(annotationId: annotationID) { success in
          if success {
            Log.debug(#file, "Server bookmark deleted: \(annotationID)")
          } else {
            Log.error(#file, "Bookmark not deleted from server. Moving on: \(annotationID)")
          }
        }
      }
    }
  }

  class func deleteBookmark(annotationId: String,
                            completionHandler: @escaping (_ success: Bool) -> ()) {

    if !syncIsPossibleAndPermitted() {
      Log.debug(#file, "Account does not support sync or sync is disabled.")
      completionHandler(true)
      return
    }

    guard let url = URL(string: annotationId) else {
      Log.error(#file, "Invalid URL from Annotation ID")
      completionHandler(false)
      return
    }

    var request = TPPNetworkExecutor.shared.request(for: url)
    request.timeoutInterval = TPPDefaultRequestTimeout

    let task = TPPNetworkExecutor.shared.DELETE(request, useTokenIfAvailable: true) { (data, response, error) in
      let response = response as? HTTPURLResponse
      if response?.statusCode == 200 {
        Log.info(#file, "200: DELETE bookmark success")
        completionHandler(true)
      } else if response?.statusCode == 404 {
        Log.error(#file, "Bookmark is no longer on the server")
        completionHandler(true)
      } else if let code = response?.statusCode {
        Log.error(#file, "DELETE bookmark failed with server response code: \(code)")
        completionHandler(false)
      } else {
        guard let error = error as NSError? else { return }
        Log.error(#file, "DELETE bookmark Request Failed with Error Code: \(error.code). Description: \(error.localizedDescription)")
        completionHandler(false)
      }
    }
  
    task?.resume()
  }

  class func uploadLocalBookmarks(_ bookmarks: [TPPReadiumBookmark],
                                  forBook bookID: String,
                                  completion: @escaping ([TPPReadiumBookmark], [TPPReadiumBookmark])->()) {
    if !syncIsPossibleAndPermitted() {
      Log.debug(#file, "Account does not support sync or sync is disabled.")
      return
    }

    Log.debug(#file, "Begin task of uploading local bookmarks, count: \(bookmarks.count).")
    let uploadGroup = DispatchGroup()
    var bookmarksFailedToUpdate = [TPPReadiumBookmark]()
    var bookmarksUpdated = [TPPReadiumBookmark]()

    for localBookmark in bookmarks {
      guard localBookmark.annotationId == nil else { continue }

      uploadGroup.enter()
      postBookmark(localBookmark, forBookID: bookID) { response in
        DispatchQueue.main.async {
          defer { uploadGroup.leave() }

          if let serverId = response?.serverId {
            localBookmark.annotationId = serverId
            bookmarksUpdated.append(localBookmark)
          } else {
            Log.error(#file, "Local Bookmark not uploaded: \(localBookmark)")
            bookmarksFailedToUpdate.append(localBookmark)
          }
        }
      }
    }

    uploadGroup.notify(queue: DispatchQueue.main) {
      Log.debug(#file, "Finished task of uploading local bookmarks.")
      completion(bookmarksUpdated, bookmarksFailedToUpdate)
    }
  }
  // MARK: -

  /// Annotation-syncing is possible only if the given `account` is signed-in
  /// and if the currently selected library supports it.
  class func syncIsPossible(_ account: TPPUserAccount) -> Bool {
    let library = AccountsManager.shared.currentAccount
    return account.hasCredentials() && library?.details?.supportsSimplyESync == true
  }

  class func syncIsPossibleAndPermitted() -> Bool {
    let acct = AccountsManager.shared.currentAccount
    return syncIsPossible(TPPUserAccount.sharedAccount()) && acct?.details?.syncPermissionGranted == true
  }

  static var annotationsURL: URL? {
    return TPPConfiguration.mainFeedURL()?.appendingPathComponent("annotations/")
  }

  private class func addToOfflineQueue(_ bookID: String?, _ url: URL, _ parameters: [String:Any]) {
    let libraryID = AccountsManager.shared.currentAccount?.uuid ?? ""
    let parameterData = try? JSONSerialization.data(withJSONObject: parameters, options: [.prettyPrinted])
    let headers = TPPNetworkExecutor.shared.request(for: url).allHTTPHeaderFields
    NetworkQueue.shared().addRequest(libraryID, bookID, url, .POST, parameterData, headers)
  }
}
