/// This class specifies the keys used to represent a TPPReadiumBookmark
/// as a dictionary.
///
/// The dictionary representation is used internally
/// to persist bookmark info to disk. It's only loosely related to the
/// `TPPBookmarkSpec` which instead specifies a cross-platform contract
/// for bookmark representation.
///
/// - Important: These keys should not change. If they did, that will mean
/// that a user won't be able to retrieve the bookmarks from disk anymore.
///
@objc class TPPBookmarkDictionaryRepresentation: NSObject {
  fileprivate static let annotationIdKey = "annotationId"
  @objc static let hrefKey = "href"
  @objc static let locationKey = "location"
  fileprivate static let timeKey = "time"
  fileprivate static let chapterKey = "chapter"
  fileprivate static let pageKey = "page"
  fileprivate static let deviceKey = "device"
  fileprivate static let chapterProgressKey = "progressWithinChapter"
  fileprivate static let bookProgressKey = "progressWithinBook"
}

protocol Bookmark: NSObject {}

/// Internal representation of an annotation. This may represent an actual
/// user bookmark as well as the "bookmark" of the last read position in a book.
@objcMembers final class TPPReadiumBookmark: NSObject, Bookmark {

  /// The bookmark ID.
  var annotationId:String?

  var chapter:String?
  var page:String?

  var location:String
  var href:String

  var progressWithinChapter:Float = 0.0
  var progressWithinBook:Float = 0.0

  var percentInChapter:String {
    return (self.progressWithinChapter * 100).roundTo(decimalPlaces: 0)
  }
  var percentInBook:String {
    return (self.progressWithinBook * 100).roundTo(decimalPlaces: 0)
  }
  
  var device:String?

  /// Date formatted as per RFC 3339
  let time:String

  init?(annotationId:String?,
        href:String?,
        chapter:String?,
        page:String?,
        location:String?,
        progressWithinChapter:Float,
        progressWithinBook:Float,
        time:String?,
        device:String?)
  {

    guard let href = href else {
      Log.error(#file, "Bookmark creation failed init due to nil `href`.")
      return nil
    }

    self.annotationId = annotationId
    self.href = href
    self.chapter = chapter ?? ""
    self.page = page ?? ""

    self.location = TPPBookLocation(
      href: href,
      type: "LocatorHrefProgression",
      chapterProgression: progressWithinChapter,
      totalProgression: progressWithinBook,
      title: chapter,
      position: nil
    )?.locationString ?? ""
    
    self.progressWithinChapter = progressWithinChapter
    self.progressWithinBook = progressWithinBook
    self.time = time ?? NSDate().rfc3339String()
    self.device = device
  }

  init?(dictionary:NSDictionary)
  {
    guard let href = dictionary[TPPBookmarkDictionaryRepresentation.hrefKey] as? String,
      let location = dictionary[TPPBookmarkDictionaryRepresentation.locationKey] as? String,
      let time = dictionary[TPPBookmarkDictionaryRepresentation.timeKey] as? String else {
        Log.error(#file, "Bookmark failed to init from dictionary.")
        return nil
    }

    if let annotationID = dictionary[TPPBookmarkDictionaryRepresentation.annotationIdKey] as? String, !annotationID.isEmpty {
      self.annotationId = annotationID
    } else {
      self.annotationId = nil
    }
    self.href = href
    self.location = location
    self.time = time
    self.chapter = dictionary[TPPBookmarkDictionaryRepresentation.chapterKey] as? String
    self.page = dictionary[TPPBookmarkDictionaryRepresentation.pageKey] as? String
    self.device = dictionary[TPPBookmarkDictionaryRepresentation.deviceKey] as? String
    if let progressChapter = dictionary[TPPBookmarkDictionaryRepresentation.chapterProgressKey] as? NSNumber {
      self.progressWithinChapter = progressChapter.floatValue
    }
    if let progressBook = dictionary[TPPBookmarkDictionaryRepresentation.bookProgressKey] as? NSNumber {
      self.progressWithinBook = progressBook.floatValue
    }
  }

  var dictionaryRepresentation:NSDictionary {
    return [
      TPPBookmarkDictionaryRepresentation.annotationIdKey: self.annotationId ?? "",
      TPPBookmarkDictionaryRepresentation.hrefKey: self.href,
      TPPBookmarkDictionaryRepresentation.chapterKey: self.chapter ?? "",
      TPPBookmarkDictionaryRepresentation.pageKey: self.page ?? "",
      TPPBookmarkDictionaryRepresentation.locationKey: self.location,
      TPPBookmarkDictionaryRepresentation.timeKey: self.time,
      TPPBookmarkDictionaryRepresentation.deviceKey: self.device ?? "",
      TPPBookmarkDictionaryRepresentation.chapterProgressKey: self.progressWithinChapter,
      TPPBookmarkDictionaryRepresentation.bookProgressKey: self.progressWithinBook
    ]
  }

  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? TPPReadiumBookmark else {
      return false
    }

    return self.href == other.href
      && self.progressWithinBook =~= other.progressWithinBook
      && self.progressWithinChapter =~= other.progressWithinChapter
      && self.chapter == other.chapter
  }
}

extension TPPReadiumBookmark {
  override var description: String {
    return "\(dictionaryRepresentation)"
  }
}

