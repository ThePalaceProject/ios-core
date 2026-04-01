import Foundation

@objc class TPPOPDSLink: NSObject {

  @objc private(set) var attributes: NSDictionary = [:]
  @objc private(set) var href: URL
  @objc private(set) var rel: String?
  @objc private(set) var type: String?
  @objc private(set) var hreflang: String?
  @objc private(set) var title: String?

  @objc init?(xml linkXML: TPPXML?) {
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
