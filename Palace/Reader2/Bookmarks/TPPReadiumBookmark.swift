// MARK: - TPPBookmarkDictionaryRepresentation

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
  fileprivate static let readingOrderItem = "readingOrderItem"
  fileprivate static let readingOrderItemOffsetMilliseconds = "readingOrderItemOffsetMilliseconds"
}

// MARK: - Bookmark

protocol Bookmark: NSObject {}

// MARK: - TPPReadiumBookmark

/// Internal representation of an annotation. This may represent an actual
/// user bookmark as well as the "bookmark" of the last read position in a book.
@objcMembers final class TPPReadiumBookmark: NSObject, Bookmark {
  /// The bookmark ID.
  var annotationId: String?

  var chapter: String?
  var page: String?

  var location: String
  var href: String

  var progressWithinChapter: Float = 0.0
  var progressWithinBook: Float = 0.0

  var readingOrderItem: String?
  var readingOrderItemOffsetMilliseconds: Float = 0.0

  var percentInChapter: String {
    (progressWithinChapter * 100).roundTo(decimalPlaces: 0)
  }

  var percentInBook: String {
    (progressWithinBook * 100).roundTo(decimalPlaces: 0)
  }

  var device: String?

  /// Date formatted as per RFC 3339
  let time: String

  init?(
    annotationId: String?,
    href: String?,
    chapter: String?,
    page: String?,
    location _: String?,
    progressWithinChapter: Float,
    progressWithinBook: Float,
    readingOrderItem: String?,
    readingOrderItemOffsetMilliseconds: Float?,
    time: String?,
    device: String?
  ) {
    guard let href = href else {
      Log.error(#file, "Bookmark creation failed init due to nil `href`.")
      return nil
    }

    self.annotationId = annotationId
    self.href = href
    self.chapter = chapter ?? ""
    self.page = page ?? ""

    location = TPPBookLocation(
      href: href,
      type: "LocatorHrefProgression",
      chapterProgression: progressWithinChapter,
      totalProgression: progressWithinBook,
      title: chapter,
      position: nil
    )?.locationString ?? ""

    self.progressWithinChapter = progressWithinChapter
    self.progressWithinBook = progressWithinBook
    self.readingOrderItem = readingOrderItem
    self.readingOrderItemOffsetMilliseconds = readingOrderItemOffsetMilliseconds ?? 0.0
    self.time = time ?? NSDate().rfc3339String()
    self.device = device
  }

  init?(dictionary: NSDictionary) {
    guard let href = dictionary[TPPBookmarkDictionaryRepresentation.hrefKey] as? String,
          let location = dictionary[TPPBookmarkDictionaryRepresentation.locationKey] as? String,
          let time = dictionary[TPPBookmarkDictionaryRepresentation.timeKey] as? String
    else {
      Log.error(#file, "Bookmark failed to init from dictionary.")
      return nil
    }

    if let annotationID = dictionary[TPPBookmarkDictionaryRepresentation.annotationIdKey] as? String,
       !annotationID.isEmpty
    {
      annotationId = annotationID
    } else {
      annotationId = nil
    }
    self.href = href
    self.location = location
    self.time = time
    chapter = dictionary[TPPBookmarkDictionaryRepresentation.chapterKey] as? String
    page = dictionary[TPPBookmarkDictionaryRepresentation.pageKey] as? String
    device = dictionary[TPPBookmarkDictionaryRepresentation.deviceKey] as? String
    readingOrderItem = dictionary[TPPBookmarkDictionaryRepresentation.readingOrderItem] as? String

    if let readingOrderItemOffsetMilliseconds =
      dictionary[TPPBookmarkDictionaryRepresentation.readingOrderItemOffsetMilliseconds] as? NSNumber
    {
      progressWithinChapter = readingOrderItemOffsetMilliseconds.floatValue
    }

    if let progressChapter = dictionary[TPPBookmarkDictionaryRepresentation.chapterProgressKey] as? NSNumber {
      progressWithinChapter = progressChapter.floatValue
    }
    if let progressBook = dictionary[TPPBookmarkDictionaryRepresentation.bookProgressKey] as? NSNumber {
      progressWithinBook = progressBook.floatValue
    }
  }

  var dictionaryRepresentation: NSDictionary {
    [
      TPPBookmarkDictionaryRepresentation.annotationIdKey: annotationId ?? "",
      TPPBookmarkDictionaryRepresentation.hrefKey: href,
      TPPBookmarkDictionaryRepresentation.chapterKey: chapter ?? "",
      TPPBookmarkDictionaryRepresentation.pageKey: page ?? "",
      TPPBookmarkDictionaryRepresentation.locationKey: location,
      TPPBookmarkDictionaryRepresentation.timeKey: time,
      TPPBookmarkDictionaryRepresentation.deviceKey: device ?? "",
      TPPBookmarkDictionaryRepresentation.chapterProgressKey: progressWithinChapter,
      TPPBookmarkDictionaryRepresentation.bookProgressKey: progressWithinBook,
      TPPBookmarkDictionaryRepresentation.readingOrderItem: readingOrderItem ?? "",
      TPPBookmarkDictionaryRepresentation.readingOrderItemOffsetMilliseconds: readingOrderItemOffsetMilliseconds,
    ]
  }

  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? TPPReadiumBookmark else {
      return false
    }

    if let id = annotationId, let otherId = other.annotationId, id == otherId {
      return true
    }

    return href == other.href
      && progressWithinBook =~= other.progressWithinBook
      && progressWithinChapter =~= other.progressWithinChapter
      && chapter == other.chapter
      && readingOrderItem == other.readingOrderItem
      && readingOrderItemOffsetMilliseconds =~= other.readingOrderItemOffsetMilliseconds
  }
}

extension TPPReadiumBookmark {
  override var description: String {
    "\(dictionaryRepresentation)"
  }
}

extension TPPReadiumBookmark {
  func toJSONDictionary() -> [String: Any] {
    var dict: [String: Any] = [:]
    dict["annotationId"] = annotationId
    dict["chapter"] = chapter
    dict["page"] = page
    dict["href"] = href
    dict["progressWithinChapter"] = progressWithinChapter
    dict["progressWithinBook"] = progressWithinBook
    dict["device"] = device
    dict["time"] = time
    dict["readingOrderItemOffsetMilliseconds"] = readingOrderItemOffsetMilliseconds
    dict["readingOrderItem"] = readingOrderItem

    if let locationData = location.data(using: .utf8),
       let locationDict = try? JSONSerialization.jsonObject(with: locationData, options: []) as? [String: Any]
    {
      for (key, value) in locationDict {
        dict[key] = value
      }
    }

    return dict
  }
}
