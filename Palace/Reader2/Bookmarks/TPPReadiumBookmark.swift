/// This class specifies the keys used to represent a TPPReadiumBookmark
/// as a dictionary.
///
/// The dictionary representation is used internally in SimplyE / OE
/// to persist bookmark info to disk. It's only loosely related to the
/// `TPPBookmarkSpec` which instead specifies a cross-platform contract
/// for bookmark representation.
///
/// - Important: These keys should not change. If they did, that will mean
/// that a user won't be able to retrieve the bookmarks from disk anymore.
///
@objc class TPPBookmarkDictionaryRepresentation: NSObject {
  fileprivate static let annotationIdKey = "annotationId"
  @objc static let idrefKey = "idref"
  @objc static let locationKey = "location"
  @objc static let cfiKey = "contentCFI"
  fileprivate static let timeKey = "time"
  fileprivate static let chapterKey = "chapter"
  fileprivate static let pageKey = "page"
  fileprivate static let deviceKey = "device"
  fileprivate static let chapterProgressKey = "progressWithinChapter"
  fileprivate static let bookProgressKey = "progressWithinBook"
}

/// Internal representation of an annotation. This may represent an actual
/// user bookmark as well as the "bookmark" of the last read position in a book.
@objcMembers final class TPPReadiumBookmark: NSObject {
  /// The bookmark ID.
  var annotationId:String?

  var chapter:String?
  var page:String?

  var location:String
  var idref:String

  /// The CFI is location information generated from the R1 reader
  /// which is not usable in R2.
  ///
  /// A CFI value refers to the content fragment identifier used to point
  /// to a specific element within the specified spine item. This was
  /// consumed by R1, but there has always been very little consistency
  /// in the values consumed by Library Simplified applications between
  /// platforms, hence its legacy and optional status.
  var contentCFI:String?

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

  /// Deprecated. 
  init?(annotationId:String?,
        contentCFI:String?,
        idref:String?,
        chapter:String?,
        page:String?,
        location:String?,
        progressWithinChapter:Float,
        progressWithinBook:Float,
        time:String?,
        device:String?)
  {
    guard let idref = idref else {
      Log.error(#file, "Bookmark creation failed init due to nil `idref`.")
      return nil
    }
    self.annotationId = annotationId
    self.contentCFI = contentCFI
    self.idref = idref
    self.chapter = chapter ?? ""
    self.page = page ?? ""

    // TODO: SIMPLY-3655 refactor per spec
    // This location structure originally comes from R1 Reader's Javascript
    // and its not available in R2, we are mimicking the structure
    // in order to pass the needed information to the server
    self.location = location ?? "{\"idref\":\"\(idref)\",\"contentCFI\":\"\(contentCFI ?? "")\"}"

    self.progressWithinChapter = progressWithinChapter
    self.progressWithinBook = progressWithinBook
    self.time = time ?? NSDate().rfc3339String()
    self.device = device
  }
  
  init?(dictionary:NSDictionary)
  {
    guard let contentCFI = dictionary[TPPBookmarkDictionaryRepresentation.cfiKey] as? String,
      let idref = dictionary[TPPBookmarkDictionaryRepresentation.idrefKey] as? String,
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
    self.contentCFI = contentCFI
    self.idref = idref
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
      TPPBookmarkDictionaryRepresentation.cfiKey: self.contentCFI ?? "",
      TPPBookmarkDictionaryRepresentation.idrefKey: self.idref,
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

    if let contentCFI = self.contentCFI,
      let otherContentCFI = other.contentCFI,
      contentCFI.count > 0 && otherContentCFI.count > 0 {
      // R1
      return self.idref == other.idref
        && self.contentCFI == other.contentCFI
        && self.location == other.location
        && self.chapter == other.chapter
    } else {
      // R2
      return self.idref == other.idref
        && self.progressWithinBook =~= other.progressWithinBook
        && self.progressWithinChapter =~= other.progressWithinChapter
        && self.chapter == other.chapter
    }
  }
}

extension TPPReadiumBookmark {
  override var description: String {
    return "\(dictionaryRepresentation)"
  }
}

