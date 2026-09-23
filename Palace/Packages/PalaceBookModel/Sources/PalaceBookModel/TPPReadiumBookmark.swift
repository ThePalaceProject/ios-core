import Foundation
import PalaceLogging

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
/// This type is the SINGLE SOURCE for these wire keys. The locator
/// round-trip in `TPPBookLocation+Locator.swift` derives its shared keys
/// from here — do not re-declare the string literals elsewhere
/// (STATE.SplitBrain: an independent copy that drifts silently breaks the
/// bookmark↔locator round-trip for persisted positions). The canonical raw
/// values are pinned by `TPPReadiumBookmarkTests.testWireFormatKeys_ArePinned`.
public class TPPBookmarkDictionaryRepresentation: NSObject {
    fileprivate static let annotationIdKey = "annotationId"
    public static let hrefKey = "href"
    static let locationKey = "location"
    public static let timeKey = "time"
    public static let chapterKey = "chapter"
    fileprivate static let pageKey = "page"
    fileprivate static let deviceKey = "device"
    public static let chapterProgressKey = "progressWithinChapter"
    public static let bookProgressKey = "progressWithinBook"
    fileprivate static let readingOrderItem = "readingOrderItem"
    fileprivate static let readingOrderItemOffsetMilliseconds = "readingOrderItemOffsetMilliseconds"
}

public protocol Bookmark: NSObject {}

/// Internal representation of an annotation. This may represent an actual
/// user bookmark as well as the "bookmark" of the last read position in a book.
public final class TPPReadiumBookmark: NSObject, Bookmark {

    /// The bookmark ID.
    public var annotationId: String?

    public var chapter: String?
    public var page: String?

    public var location: String
    public var href: String

    public var progressWithinChapter: Float = 0.0
    public var progressWithinBook: Float = 0.0

    public var readingOrderItem: String?
    public var readingOrderItemOffsetMilliseconds: Float = 0.0

    public var percentInChapter: String {
        return (self.progressWithinChapter * 100).roundTo(decimalPlaces: 0)
    }
    public var percentInBook: String {
        return (self.progressWithinBook * 100).roundTo(decimalPlaces: 0)
    }

    public var device: String?

    /// Date formatted as per RFC 3339
    public let time: String

    /// Package designated initializer taking a pre-resolved `locationString`.
    /// The full-field initializer that derives the location string via the
    /// Readium-backed `TPPBookLocation(href:type:...)` convenience init lives
    /// app-side in `TPPReadiumBookmark+R3.swift` (ReadiumShared cannot cross
    /// into this leaf model package) and delegates here — Wave 2a extraction,
    /// behavior byte-identical.
    public init(annotationId: String?,
                href: String,
                chapter: String?,
                page: String?,
                locationString: String,
                progressWithinChapter: Float,
                progressWithinBook: Float,
                readingOrderItem: String?,
                readingOrderItemOffsetMilliseconds: Float,
                time: String,
                device: String?) {
        self.annotationId = annotationId
        self.href = href
        self.chapter = chapter ?? ""
        self.page = page ?? ""
        self.location = locationString
        self.progressWithinChapter = progressWithinChapter
        self.progressWithinBook = progressWithinBook
        self.readingOrderItem = readingOrderItem
        self.readingOrderItemOffsetMilliseconds = readingOrderItemOffsetMilliseconds
        self.time = time
        self.device = device
        super.init()
    }

    public init?(dictionary: NSDictionary) {
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
        self.readingOrderItem = dictionary[TPPBookmarkDictionaryRepresentation.readingOrderItem] as? String

        // P0 #2 (swarm `swarm_f3b9b087`): mixed-format dictionaries from
        // older app versions may carry BOTH the audiobook-style
        // `readingOrderItemOffsetMilliseconds` AND the canonical EPUB
        // `progressWithinChapter`. Contract:
        //
        //   1. If `progressWithinChapter` (chapterProgressKey) is present,
        //      it wins — it is the canonical EPUB key for in-chapter
        //      progression and is the value the EPUB reader actually
        //      sets when persisting a bookmark.
        //   2. Otherwise, fall back to `readingOrderItemOffsetMilliseconds`
        //      so legacy audiobook-style dictionaries still hydrate a
        //      meaningful `progressWithinChapter` value.
        //
        // Implemented as `if/else` (rather than the prior two unconditional
        // assignments) so the precedence is explicit at the call site —
        // a refactor flipping the order will now silently mutate behavior
        // instead of compiling cleanly.
        if let progressChapter = dictionary[TPPBookmarkDictionaryRepresentation.chapterProgressKey] as? NSNumber {
            self.progressWithinChapter = progressChapter.floatValue
        } else if let readingOrderItemOffsetMilliseconds = dictionary[TPPBookmarkDictionaryRepresentation.readingOrderItemOffsetMilliseconds] as? NSNumber {
            self.progressWithinChapter = readingOrderItemOffsetMilliseconds.floatValue
        }
        if let progressBook = dictionary[TPPBookmarkDictionaryRepresentation.bookProgressKey] as? NSNumber {
            self.progressWithinBook = progressBook.floatValue
        }
    }

    public var dictionaryRepresentation: NSDictionary {
        return [
            TPPBookmarkDictionaryRepresentation.annotationIdKey: self.annotationId ?? "",
            TPPBookmarkDictionaryRepresentation.hrefKey: self.href,
            TPPBookmarkDictionaryRepresentation.chapterKey: self.chapter ?? "",
            TPPBookmarkDictionaryRepresentation.pageKey: self.page ?? "",
            TPPBookmarkDictionaryRepresentation.locationKey: self.location,
            TPPBookmarkDictionaryRepresentation.timeKey: self.time,
            TPPBookmarkDictionaryRepresentation.deviceKey: self.device ?? "",
            TPPBookmarkDictionaryRepresentation.chapterProgressKey: self.progressWithinChapter,
            TPPBookmarkDictionaryRepresentation.bookProgressKey: self.progressWithinBook,
            TPPBookmarkDictionaryRepresentation.readingOrderItem: self.readingOrderItem ?? "",
            TPPBookmarkDictionaryRepresentation.readingOrderItemOffsetMilliseconds: self.readingOrderItemOffsetMilliseconds
        ]
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TPPReadiumBookmark else {
            return false
        }

        if let id = annotationId, let otherId = other.annotationId, id == otherId { return true }

        return self.href == other.href
            && self.progressWithinBook =~= other.progressWithinBook
            && self.progressWithinChapter =~= other.progressWithinChapter
            && self.chapter == other.chapter
            && self.readingOrderItem == other.readingOrderItem
            && self.readingOrderItemOffsetMilliseconds =~= other.readingOrderItemOffsetMilliseconds
    }
}

extension TPPReadiumBookmark {
    public override var description: String {
        return "\(dictionaryRepresentation)"
    }
}

extension TPPReadiumBookmark {
    public func toJSONDictionary() -> [String: Any] {
        var dict: [String: Any] = [:]
        dict[TPPBookmarkDictionaryRepresentation.annotationIdKey] = self.annotationId
        dict[TPPBookmarkDictionaryRepresentation.chapterKey] = self.chapter
        dict[TPPBookmarkDictionaryRepresentation.pageKey] = self.page
        dict[TPPBookmarkDictionaryRepresentation.hrefKey] = self.href
        dict[TPPBookmarkDictionaryRepresentation.chapterProgressKey] = self.progressWithinChapter
        dict[TPPBookmarkDictionaryRepresentation.bookProgressKey] = self.progressWithinBook
        dict[TPPBookmarkDictionaryRepresentation.deviceKey] = self.device
        dict[TPPBookmarkDictionaryRepresentation.timeKey] = self.time
        dict[TPPBookmarkDictionaryRepresentation.readingOrderItemOffsetMilliseconds] = self.readingOrderItemOffsetMilliseconds
        dict[TPPBookmarkDictionaryRepresentation.readingOrderItem] = self.readingOrderItem

        if let locationData = self.location.data(using: .utf8),
           let locationDict = try? JSONSerialization.jsonObject(with: locationData, options: []) as? [String: Any] {
            for (key, value) in locationDict {
                dict[key] = value
            }
        }

        return dict
    }
}