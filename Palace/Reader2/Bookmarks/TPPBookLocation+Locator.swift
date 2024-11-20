import Foundation
import ReadiumShared

extension TPPBookLocation {
  static let r3Renderer = "readium3"

  // Initialize from Locator
  convenience init?(locator: Locator,
                    type: String,
                    publication: Publication,
                    renderer: String = TPPBookLocation.r3Renderer) {

    let dict: [String: Any] = [
      TPPBookLocation.hrefKey: locator.href.string,
      TPPBookLocation.typeKey: type,
      TPPBookLocation.chapterProgressKey: locator.locations.progression ?? 0.0,
      TPPBookLocation.bookProgressKey: locator.locations.totalProgression ?? 0.0,
      TPPBookLocation.titleKey: locator.title ?? "",
      TPPBookLocation.positionKey: locator.locations.position ?? 0,
      TPPBookLocation.cssSelector: locator.locations.otherLocations[TPPBookLocation.cssSelector] ?? ""
    ]

    guard let jsonString = serializeJSONString(dict) else {
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

    // Ensure href is converted to a valid format
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

    guard let jsonString = serializeJSONString(dict) else {
      Log.warn(#file, "Failed to serialize JSON string from dictionary - \(dict.debugDescription)")
      return nil
    }

    self.init(locationString: jsonString, renderer: renderer)
  }

  func convertToLocator(publication: Publication) async -> Locator? {
    guard self.renderer == TPPBookLocation.r3Renderer,
          let data = self.locationString.data(using: .utf8),
          let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
      Log.error(#file, "Failed to convert TPPBookLocation to Locator with string: \(locationString)")
      return nil
    }

    let hrefString = dict[TPPBookLocation.hrefKey] as? String ?? ""
    guard
      let url = AnyURL(string: hrefString),
      let publicationLink = publication.linkWithHREF(url),
      let mediaType = publicationLink.mediaType,
      let publicationHref = AnyURL(string: publicationLink.href)
    else {
      Log.error(#file, "Failed to resolve HREF in publication: \(hrefString)")
      return nil
    }

    let title = dict[TPPBookLocation.titleKey] as? String ?? ""
    let position = dict[TPPBookLocation.positionKey] as? Int ?? 1

    let locations = Locator.Locations(
      fragments: [],
      progression: dict[TPPBookLocation.chapterProgressKey] as? Double,
      totalProgression: dict[TPPBookLocation.bookProgressKey] as? Double,
      position: position,
      otherLocations: dict[TPPBookLocation.cssSelector] != nil ? [TPPBookLocation.cssSelector: dict[TPPBookLocation.cssSelector]!] : [:]
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
  static let hrefKey = "href"
  static let typeKey = "@type"
  static let chapterProgressKey = "progressWithinChapter"
  static let bookProgressKey = "progressWithinBook"
  static let titleKey = "title"
  static let timeKey = "time"
  static let partKey = "part"
  static let chapterKey = "chapter"
  static let positionKey = "position"
  static let cssSelector = "cssSelector"
}
