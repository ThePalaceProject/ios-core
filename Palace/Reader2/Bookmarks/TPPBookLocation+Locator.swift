import Foundation
import ReadiumShared

extension TPPBookLocation {
  static let r2Renderer = "readium2"

  // Initialize from Locator
  convenience init?(locator: Locator,
                    type: String,
                    publication: Publication,
                    renderer: String = TPPBookLocation.r2Renderer) {
    // Update the dictionary to store locator properties
    let dict: [String: Any] = [
      TPPBookLocation.hrefKey: locator.href,
      TPPBookLocation.typeKey: type,
      TPPBookLocation.chapterProgressKey: locator.locations.progression ?? 0.0,
      TPPBookLocation.bookProgressKey: locator.locations.totalProgression ?? 0.0,
      TPPBookLocation.titleKey: locator.title ?? "",
      TPPBookLocation.positionKey: locator.locations.position ?? 0,
      TPPBookLocation.cssSelector: locator.locations.otherLocations[TPPBookLocation.cssSelector] ?? ""
    ]

    guard let jsonString = serializeJSONString(dict) else {
      Log.warn(#file, "Failed to serialize json string from dictionary - \(dict.debugDescription)")
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
                    position: Int? = nil,
                    cssSelector: String? = nil,
                    publication: Publication? = nil,
                    renderer: String = TPPBookLocation.r2Renderer) {

    let dict: [String: Any] = [
      TPPBookLocation.hrefKey: href,
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
      Log.warn(#file, "Failed to serialize json string from dictionary - \(dict.debugDescription)")
      return nil
    }

    self.init(locationString: jsonString, renderer: renderer)
  }

  // Convert to Locator object
  func convertToLocator() -> Locator? {
    guard self.renderer == TPPBookLocation.r2Renderer,
          let data = self.locationString.data(using: .utf8),
          let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
          let hrefString = dict[TPPBookLocation.hrefKey] as? String,
          let type = dict[TPPBookLocation.typeKey] as? String,
          let mediaType = MediaType(type),
          let progressWithinChapter = dict[TPPBookLocation.chapterProgressKey] as? Double,
          let progressWithinBook = dict[TPPBookLocation.bookProgressKey] as? Double else {
      Log.error(#file, "Failed to convert TPPBookLocation to Locator object with location string: \(locationString)")
      return nil
    }

    // Convert the href string to a typed URL (FileURL, HTTPURL, etc.)
    guard let href = FileURL(string: hrefString)?.httpURL ?? HTTPURL(string: hrefString) else {
      Log.error(#file, "Invalid href URL: \(hrefString)")
      return nil
    }

    let title: String = dict[TPPBookLocation.titleKey] as? String ?? ""
    let position: Int? = dict[TPPBookLocation.positionKey] as? Int

    var otherLocations = [String: Any]()
    if let cssSelector = dict[TPPBookLocation.cssSelector] as? String, !cssSelector.isEmpty {
      otherLocations[TPPBookLocation.cssSelector] = cssSelector
    }

    let locations = Locator.Locations(fragments: [],
                                      progression: progressWithinChapter,
                                      totalProgression: progressWithinBook,
                                      position: position,
                                      otherLocations: otherLocations)

    return Locator(href: href,
                   mediaType: mediaType,
                   title: title,
                   locations: locations)
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
