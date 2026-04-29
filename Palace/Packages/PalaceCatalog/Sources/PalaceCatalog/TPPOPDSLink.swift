import Foundation
import PalaceLogging

@objc public class TPPOPDSLink: NSObject {

  @objc public private(set) var attributes: NSDictionary = [:]
  @objc public private(set) var href: URL
  @objc public private(set) var rel: String?
  @objc public private(set) var type: String?
  @objc public private(set) var hreflang: String?
  @objc public private(set) var title: String?

  @objc public init?(xml linkXML: TPPXML?) {
    guard let linkXML = linkXML else { return nil }
    let attrs = linkXML.attributes as? [String: String] ?? [:]

    guard let hrefString = attrs["href"],
          let href = URL(string: hrefString) else {
      Log.log("Missing required 'href' attribute or 'href' does not contain a valid URI.")
      return nil
    }

    self.href = href
    self.attributes = linkXML.attributes
    self.rel = attrs["rel"]
    self.type = attrs["type"]
    self.hreflang = attrs["hreflang"]
    self.title = attrs["title"]
    super.init()
  }
}
