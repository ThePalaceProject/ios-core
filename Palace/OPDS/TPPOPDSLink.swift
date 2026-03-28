import Foundation

// MARK: - TPPOPDSLink (Swift port of TPPOPDSLink.m)

/// Swift reimplementation of the ObjC TPPOPDSLink model.
/// Initialized from a TPPXML element representing an OPDS `<link>`.
@objc(TPPOPDSLinkSwift)
public final class TPPOPDSLinkSwift: NSObject {

  @objc public let attributes: NSDictionary
  @objc public let href: URL
  @objc public let rel: String?
  @objc public let type: String?
  @objc public let hreflang: String?
  @objc public let title: String?

  /// Designated initializer.
  /// Returns `nil` if the XML element lacks a valid `href` attribute.
  @objc public init?(xml linkXML: TPPXML) {
    guard let hrefString = linkXML.attributes["href"] as? String,
          let hrefURL = URL(string: hrefString) else {
      Log.warn(#file, "Missing or invalid required 'href' attribute.")
      return nil
    }

    self.attributes = linkXML.attributes as NSDictionary
    self.href = hrefURL
    self.rel = linkXML.attributes["rel"] as? String
    self.type = linkXML.attributes["type"] as? String
    self.hreflang = linkXML.attributes["hreflang"] as? String
    self.title = linkXML.attributes["title"] as? String
    super.init()
  }

  /// Memberwise initializer for programmatic construction.
  @objc public init(href: URL, rel: String?, type: String?, hreflang: String?, title: String?, attributes: NSDictionary) {
    self.href = href
    self.rel = rel
    self.type = type
    self.hreflang = hreflang
    self.title = title
    self.attributes = attributes
    super.init()
  }
}
