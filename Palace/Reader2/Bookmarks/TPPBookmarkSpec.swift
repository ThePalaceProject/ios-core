//
//  TPPBookmarkSpec.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 3/24/21.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

/// A type representing the [format](https://github.com/ThePalaceProject/mobile-bookmark-spec) of bookmark data
/// shared between clients nd server in the Library Simplified ecosystem.
///
/// The structure of this type mimics the structure of the spec, as one
/// can see from the [provided examples](https://github.com/ThePalaceProject/mobile-bookmark-spec/blob/main/valid-bookmark-0.json).
/// All required keys are listed. When a `value` property is present,
/// it means it's a required fixed value. E.g. the `"type"` key *MUST*
/// have a value equal to the `"Annotation"` literal. Fields that allow more
/// more than one fixed value are expressed with enums (e.g. see `Motivation`.)
///
/// Bookmarks created inside the R2 reader *MUST* provide a value for all
/// the keys listed here; exceptions are noted on each individual field.
///
/// Bookmarks created inside the R1 reader *MAY* comply to the same spec
/// and historically some of the key/values overlap, although there has not
/// been consistence in how those bookmarks are defined, especially
/// cross-platform.
///
/// See the [full spec](https://github.com/ThePalaceProject/mobile-bookmark-spec)
/// for more details.
struct TPPBookmarkSpec {
  struct Context {
    /// The key identifying the `Context` section.
    static let key = "@context"
    /// The only possible value for the `Context` section key.
    static let value = "http://www.w3.org/ns/anno.jsonld"
  }

  struct type {
    /// The key identifying the `Type` section.
    static let key = "type"
    /// The only possible value for the `Type` section key.
    static let value = "Annotation"
  }

  struct Id {
    /// The key identifying the `Id` section.
    static let key = "id"
    /// The value of the annotation ID.
    let value: String?
  }

  /// See hhttps://github.com/ThePalaceProject/mobile-bookmark-spec#bodies.
  struct Body {
    /// The key identifying the `Body` section.
    static let key = "body"

    struct Time {
      static let key = "http://librarysimplified.org/terms/time"
      /// The `Time` value is a timestamp string formatted per
      /// [RFC 3339](https://tools.ietf.org/html/rfc3339).
      /// The timestamp value itself must be in UTC time zone.
      let value: String
    }
    let time: Time

    struct Device {
      static let key = "http://librarysimplified.org/terms/device"
      /// Clients that do not have access to an actual DRM device identifier
      /// _SHOULD_ use this value.
      static let nullValue = "null"
      /// The Device value is a DRM device identifier, such as what is
      /// provided by `NYPLUserAccount::deviceID`.
      let value: String
    }
    let device: Device
    
    struct ChapterTitle {
      static let key = "http://librarysimplified.org/terms/chapter"
      let value: String
    }
    let chapterTitle: ChapterTitle

    struct ProgressWithinBook {
      static let key = "http://librarysimplified.org/terms/progressWithinBook"
      let value: Double
    }
    let progressWithinBook: ProgressWithinBook

    init(time: String, device: String, chapterTitle: String, progressWithinBook: Double) {
      self.time = Time(value: time)
      self.device = Device(value: device)
      self.chapterTitle = ChapterTitle(value: chapterTitle)
      self.progressWithinBook = ProgressWithinBook(value: progressWithinBook)
    }
  }

  /// See https://github.com/ThePalaceProject/mobile-bookmark-spec#motivations
  enum Motivation: String {
    /// The key identifying the `Motivation` section.
    static let key = "motivation"
    /// The keyword identifying an explicit bookmark in a textual search.
    static let bookmarkingKeyword = "bookmarking"
    /// The motivation value for an explicit user bookmark.
    case bookmark = "http://www.w3.org/ns/oa#bookmarking"
    /// The motivation value for the implicit bookmark related to the last
    /// read position.
    case readingProgress = "http://librarysimplified.org/terms/annotation/idling"
  }

  /// See https://github.com/ThePalaceProject/mobile-bookmark-spec#targets
  struct Target {
    static let key = "target"

    struct Selector {
      static let key = "selector"

      /// The Selector `type` has always a fixed value.
      struct type {
        /// The key identifying the Selector type.
        static let key = "type"
        /// The only possible value for the Selector's `Type` key.
        static let value = "oa:FragmentSelector"
      }

      /// The Selector `Value` contains a [locator](https://git.io/JYTyx)
      /// serialized as a JSON string. This type defines the possible
      /// locator's keys, as well as required values.
      struct Value {
        /// The key identifying the Selector `Value`.
        static let key = "value"

        /// The locator key identifying its type. This key will appear inside
        /// the `selectorValue` String.
        static let locatorTypeKey = "@type"
        /// The only value for the `locatorTypeKey` field for all non-legacy
        /// locators supported by this spec. This will appear inside
        /// the `selectorValue` String.
        static let locatorTypeValue = "LocatorHrefProgression"
        /// The locator key identifying the chapter id of the bookmark.
        /// This key will appear inside the `selectorValue` String.
        static let locatorChapterIDKey = "href"
        /// The locator key identifying the progression % inside the chapter.
        /// This key will appear inside the `selectorValue` String.
        static let locatorChapterProgressionKey = "progressWithinChapter"

        /// Locators can be expressed in a legacy format using CFI to
        /// identify the position in the book. In that case, the value for
        /// `locatorTypeKey` is expressed by this constant.
        static let legacyLocatorTypeValue = "LocatorLegacyCFI"
        /// This is a key related to an optional Selector Value field,
        /// provided for backward compatibility with R1 bookmarks.
        static let legacyLocatorCFIKey = "contentCFI"

        /// A serialized JSON string (its keys and values are escaped)
        /// containing a [locator](https://git.io/JYTyx), e.g.
        /// "{\"@type\": \"LocatorHrefProgression\", \"href\": \"/xyz.html\",
        ///   \"progressWithinChapter\": 0.5}"
        let selectorValue: String
      }
      let value: Value
    } //Selector
    let selector: Selector

    struct Source {
      static let key = "source"
      /// Typically the book ID from the OPDS feed.
      let value: String
    }
    let source: Source

    init(bookID: String, selectorValue: String) {
      self.source = Source(value: bookID)
      self.selector = Selector(value: Selector.Value(selectorValue: selectorValue))
    }
  }

  let id: Id
  let body: Body
  let motivation: Motivation
  let target: Target

  init(id: String? = nil,
       time: NSDate,
       device: String,
       motivation: Motivation,
       bookID: String,
       selectorValue: String) {
    self.id = Id(value: id)

    var title = ""
    var progressWithinBook = 0.0

    if let value = selectorValue.data(using: .utf8),
       let dict = try? JSONSerialization.jsonObject(with: value, options: []) as? [String: Any] {
      title = dict["title"] as? String ?? ""
      progressWithinBook = dict["progressWithinBook"] as? Double ?? 0.0
    }
  
    self.body = Body(time: time.rfc3339String(), device: device, chapterTitle: title, progressWithinBook: progressWithinBook)
    self.motivation = motivation
    self.target = Target(bookID: bookID, selectorValue: selectorValue)
  }

  /// - returns: A dictionary that can be given to `JSONSerialization` as a
  /// JSON object to be serialized into a binary Data blob.
  func dictionaryForJSONSerialization() -> [String: Any] {
    return [
      TPPBookmarkSpec.Context.key: TPPBookmarkSpec.Context.value,
      TPPBookmarkSpec.type.key: TPPBookmarkSpec.type.value,
      TPPBookmarkSpec.Body.key: [
        TPPBookmarkSpec.Body.Time.key : body.time.value,
        TPPBookmarkSpec.Body.Device.key : body.device.value,
        TPPBookmarkSpec.Body.ChapterTitle.key: body.chapterTitle.value
      ],
      TPPBookmarkSpec.Motivation.key: motivation.rawValue,
      TPPBookmarkSpec.Target.key: [
        TPPBookmarkSpec.Target.Source.key: target.source.value,
        TPPBookmarkSpec.Target.Selector.key: [
          TPPBookmarkSpec.Target.Selector.type.key: TPPBookmarkSpec.Target.Selector.type.value,
          TPPBookmarkSpec.Target.Selector.Value.key: target.selector.value.selectorValue
        ]
      ]
      ] as [String: Any]
  }
}
