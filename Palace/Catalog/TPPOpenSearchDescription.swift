import Foundation

// MARK: - TPPOpenSearchDescription (Swift port of TPPOpenSearchDescription.m)

/// Swift reimplementation of the ObjC TPPOpenSearchDescription model.
/// Represents OpenSearch description documents containing URLs to OPDS feeds.
@objc(TPPOpenSearchDescriptionSwift)
public final class TPPOpenSearchDescriptionSwift: NSObject {

  @objc public let humanReadableDescription: String
  @objc public let opdsURLTemplate: String?
  @objc public let books: [Any]?

  /// Initializes from an OpenSearch description XML document.
  /// Returns `nil` if the XML does not contain a valid description or OPDS URL.
  @objc public init?(xml osdXML: TPPXML) {
    guard let description = osdXML.firstChild(withName: "Description")?.value else {
      Log.warn(#file, "Missing required description element.")
      return nil
    }
    self.humanReadableDescription = description

    var template: String?
    for urlObj in osdXML.children(withName: "Url") {
      guard let urlXML = urlObj as? TPPXML else { continue }
      if let type = urlXML.attributes["type"] as? String,
         type.range(of: "opds-catalog") != nil {
        template = urlXML.attributes["template"] as? String
        break
      }
    }

    guard let opdsTemplate = template else {
      Log.warn(#file, "Missing expected OPDS URL.")
      return nil
    }
    self.opdsURLTemplate = opdsTemplate
    self.books = nil

    super.init()
  }

  /// Initializes for local search results.
  @objc public init(title: String, books: [Any]) {
    self.humanReadableDescription = title
    self.books = books
    self.opdsURLTemplate = nil
    super.init()
  }

  /// Uses the OPDS URL template to create a URL with the given search terms.
  @objc public func opdsURL(forSearchingString searchString: String) -> URL? {
    guard let template = opdsURLTemplate else { return nil }
    let encoded = searchString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? searchString
    let urlString = template.replacingOccurrences(of: "{searchTerms}", with: encoded)
    return URL(string: urlString)
  }

  /// Fetches an OpenSearch description from a URL.
  @objc public static func withURL(
    _ url: URL?,
    shouldResetCache: Bool,
    completionHandler handler: @escaping (TPPOpenSearchDescription?) -> Void
  ) {
    // Delegate to the existing ObjC implementation which uses TPPSession.
    TPPOpenSearchDescription.withURL(
      url,
      shouldResetCache: shouldResetCache,
      completionHandler: handler
    )
  }
}
