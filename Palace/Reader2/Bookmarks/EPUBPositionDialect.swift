//
//  EPUBPositionDialect.swift
//  The Palace Project
//
//  A reading position or bookmark can reach Palace as either of two JSON
//  dialects, and both are live on the annotation server today:
//
//    Readium `Locator` — what Palace POSTed before PP-5138, and what is
//    still stored server-side for every position written by a shipped
//    client:
//      {"href":…,"type":…,"title":…,
//       "locations":{"progression":…,"totalProgression":…,"position":…}}
//
//    Flat Palace / `mobile-specs` `LocatorHrefProgression` — what the local
//    book registry stores, what `TPPReadiumBookmark` writes, what older
//    clients POSTed, and what Palace POSTs as of PP-5138:
//      {"href":…,"@type":…,"progressWithinChapter":…,
//       "progressWithinBook":…,"position":…,"cssSelector":…}
//
//  This type reads either one, which is what makes the write-side change
//  safe: positions already stored in the Readium dialect keep resolving.
//
//  NOTE: an earlier revision of this comment said the change was "the READ
//  side only". That stopped being true in commit 595d6b354, which brought
//  the write side into scope — see the 2026-09-16 amendment in
//  `.forgeos/intent/pp5138-epub-position-read-dialect.md`. Palace now emits
//  the flat shape `ThePalaceProject/mobile-specs` specifies and Android
//  already parses.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// The position fields Palace needs, parsed from either dialect.
///
/// Nested `locations` values win when present; the flat keys are the
/// fallback. Reading in that order means a payload carrying both (an older
/// Palace position that also grew a `locations` object, say) resolves to the
/// Readium reading rather than half of each.
struct EPUBPositionDialect: Equatable {

    let href: String?
    let title: String?
    let progression: Double?
    let totalProgression: Double?
    let position: Int?
    let cssSelector: String?

    // MARK: - Wire keys

    private enum Key {
        // Shared between dialects.
        static let href = "href"
        static let title = "title"
        static let position = "position"
        static let cssSelector = "cssSelector"
        // Readium `Locator`.
        static let locations = "locations"
        static let progression = "progression"
        static let totalProgression = "totalProgression"
        // Flat Palace.
        static let progressWithinChapter = "progressWithinChapter"
        static let progressWithinBook = "progressWithinBook"
    }

    // MARK: - Parsing

    init?(jsonString: String) {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        self.init(data: data)
    }

    init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any] else {
            return nil
        }
        self.init(dictionary: dict)
    }

    init(dictionary dict: [String: Any]) {
        let locations = dict[Key.locations] as? [String: Any]

        href = dict[Key.href] as? String
        title = dict[Key.title] as? String

        progression = Self.double(locations?[Key.progression])
            ?? Self.double(dict[Key.progressWithinChapter])
        totalProgression = Self.double(locations?[Key.totalProgression])
            ?? Self.double(dict[Key.progressWithinBook])
        position = Self.int(locations?[Key.position])
            ?? Self.int(dict[Key.position])
        cssSelector = locations?[Key.cssSelector] as? String
            ?? dict[Key.cssSelector] as? String
    }

    /// JSON numbers arrive as `NSNumber` regardless of whether they were
    /// written as `0.62` or `58`, so both accessors go through it. A direct
    /// `as? Double` on an integer-valued `NSNumber` works, but `as? Int` on a
    /// fractional one returns nil (Swift checks exactness) — which would
    /// silently drop a position written as `58.0`.
    private static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    // MARK: - Same-page comparison

    /// The fields that decide whether two positions point at the same page.
    ///
    /// Absent values normalize to zero / empty because the two dialects
    /// disagree about absence: the flat writer coerces a nil progression to
    /// `0.0` and always emits the key, while the Readium writer omits it. Left
    /// un-normalized, `0.0` and `nil` would read as different pages and the
    /// comparison would be as useless as the string equality it replaces.
    ///
    /// Title and media type are excluded — they describe the position, they
    /// do not locate it.
    struct PositionIdentity: Equatable {
        let href: String
        let progression: Double
        let totalProgression: Double
        let position: Int
        let cssSelector: String
    }

    var positionIdentity: PositionIdentity {
        PositionIdentity(
            href: href ?? "",
            progression: progression ?? 0,
            totalProgression: totalProgression ?? 0,
            position: position ?? 0,
            cssSelector: cssSelector ?? ""
        )
    }

    /// Whether two serialized positions point at the same page, whatever
    /// dialect each is written in.
    ///
    /// Falls back to byte equality when either side cannot be parsed, so an
    /// unrecognized payload is never treated as matching something it does
    /// not — the pre-PP-5138 behavior, preserved for the unparseable case.
    static func samePosition(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = EPUBPositionDialect(jsonString: lhs),
              let right = EPUBPositionDialect(jsonString: rhs) else {
            return lhs == rhs
        }
        return left.positionIdentity == right.positionIdentity
    }
}
