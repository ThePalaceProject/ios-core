import Foundation
import ReadiumShared
import PalaceLogging
import PalaceBookModel

extension TPPBookLocation {
    static let r3Renderer = "readium3"

    convenience init?(locator: Locator,
                      type: String,
                      publication: Publication,
                      renderer: String = TPPBookLocation.r3Renderer) {

        let dict: [String: Any] = [
            TPPBookLocation.hrefKey: locator.href.string,
            TPPBookLocation.typeKey: type,
            TPPBookLocation.chapterProgressKey: TPPBookLocation.unitInterval(locator.locations.progression),
            TPPBookLocation.bookProgressKey: TPPBookLocation.unitInterval(locator.locations.totalProgression),
            TPPBookLocation.titleKey: locator.title ?? "",
            TPPBookLocation.positionKey: locator.locations.position ?? 0,
            TPPBookLocation.cssSelector: locator.locations.otherLocations[TPPBookLocation.cssSelector]?.string ?? ""
        ]

        guard let jsonString = TPPBookLocation.jsonString(from: dict) else {
            Log.warn(#file, "Failed to serialize JSON string from dictionary - \(dict.debugDescription)")
            return nil
        }

        self.init(locationString: jsonString, renderer: renderer)
    }

    // Initialize with properties directly
    convenience init?(href: String,
                      type: String,
                      time: Double? = nil,
                      part: Float? = nil,
                      chapter: String? = nil,
                      chapterProgression: Float? = nil,
                      totalProgression: Float? = nil,
                      title: String? = nil,
                      position: Double? = nil,
                      cssSelector: String? = nil,
                      publication: Publication? = nil,
                      renderer: String = TPPBookLocation.r3Renderer) {

        guard let normalizedHref = AnyURL(legacyHREF: href)?.string else {
            Log.warn(#file, "Invalid href format")
            return nil
        }

        let dict: [String: Any] = [
            TPPBookLocation.hrefKey: normalizedHref,
            TPPBookLocation.typeKey: type,
            TPPBookLocation.timeKey: time ?? 0.0,
            TPPBookLocation.partKey: part ?? 0.0,
            TPPBookLocation.chapterKey: chapter ?? "",
            TPPBookLocation.chapterProgressKey: chapterProgression ?? 0.0,
            TPPBookLocation.bookProgressKey: totalProgression ?? 0.0,
            TPPBookLocation.titleKey: title ?? "",
            TPPBookLocation.positionKey: position ?? 0,
            TPPBookLocation.cssSelector: cssSelector ?? ""
        ]

        guard let jsonString = TPPBookLocation.jsonString(from: dict) else {
            Log.warn(#file, "Failed to serialize JSON string from dictionary - \(dict.debugDescription)")
            return nil
        }

        self.init(locationString: jsonString, renderer: renderer)
    }

    /// Clamps a progression to the 0.0…1.0 the bookmark spec requires, mapping
    /// a missing value to 0.0.
    ///
    /// The spec's schema declares `minimum: 0.0` / `maximum: 1.0`, and Android
    /// enforces it with a constructor `check` that THROWS on a value outside
    /// the range. That throw escapes the per-annotation catch and is swallowed
    /// by a blanket handler that returns an empty list — so a single
    /// out-of-range progression from this client silently empties the patron's
    /// entire bookmark set on their Android device. Clamping here costs
    /// nothing: Readium already reports progressions in range, so this only
    /// ever fires on a value that would have been rejected anyway.
    private static func unitInterval(_ value: Double?) -> Double {
        min(max(value ?? 0.0, 0.0), 1.0)
    }

    /// Serializes a location dictionary to a JSON string. Replaces Readium's
    /// `serializeJSONString` free function, removed in the 3.9.0 JSONValue
    /// migration. The payload is a plain Foundation `[String: Any]`, so
    /// Foundation's `JSONSerialization` is the natural fit and round-trips with
    /// the `JSONSerialization.jsonObject` deserialization in `convertToLocator`.
    private static func jsonString(from dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func convertToLocator(publication: Publication) async -> Locator? {
        guard self.renderer == TPPBookLocation.r3Renderer,
              let data = self.locationString.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            Log.error(#file, "Failed to convert TPPBookLocation to Locator with string: \(locationString)")
            return nil
        }

        // PP-5138: the bytes reaching here are the flat Palace dialect when they
        // come from the local registry, but the Readium `Locator` dialect when
        // they come from the annotation server — that is what Palace POSTs.
        // Reading only the flat keys made every server-sourced position resolve
        // to nil progression and position 1, so "Move" landed the patron at the
        // top of the chapter instead of where they left off.
        let fields = EPUBPositionDialect(dictionary: dict)

        let hrefString = fields.href ?? ""
        guard
            let url = AnyURL(string: hrefString),
            let publicationLink = publication.linkWithHREF(url),
            let mediaType = publicationLink.mediaType,
            let publicationHref = AnyURL(string: publicationLink.href)
        else {
            Log.error(#file, "Failed to resolve HREF in publication: \(hrefString)")
            return nil
        }

        let title = fields.title ?? ""
        // `?? 1` is the long-standing fallback for a payload with no position
        // at all; it is deliberately not `0`, which Readium reads as "before
        // the first page".
        let position = fields.position ?? 1

        let locations = Locator.Locations(
            fragments: [],
            progression: fields.progression,
            totalProgression: fields.totalProgression,
            position: position,
            otherLocations: JSONValue(fields.cssSelector).map { [TPPBookLocation.cssSelector: $0] } ?? [:]
        )

        return Locator(
            href: publicationHref,
            mediaType: mediaType,
            title: title,
            locations: locations
        )
    }
}

private extension TPPBookLocation {
    // Shared wire keys derive from the single source of truth in
    // `TPPBookmarkDictionaryRepresentation` — these strings are a persisted
    // disk format shared with the bookmark round-trip and must never drift
    // (STATE.SplitBrain fix, 2026-07-05).
    static let hrefKey = TPPBookmarkDictionaryRepresentation.hrefKey
    static let chapterProgressKey = TPPBookmarkDictionaryRepresentation.chapterProgressKey
    static let bookProgressKey = TPPBookmarkDictionaryRepresentation.bookProgressKey
    static let timeKey = TPPBookmarkDictionaryRepresentation.timeKey
    static let chapterKey = TPPBookmarkDictionaryRepresentation.chapterKey
    // Locator-only keys (not part of the bookmark dictionary format):
    static let typeKey = "@type"
    static let titleKey = "title"
    static let partKey = "part"
    static let positionKey = "position"
    static let cssSelector = "cssSelector"
}
