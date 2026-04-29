import Foundation

@objc public class TPPOPDSEntryGroupAttributes: NSObject {

  @objc public private(set) var href: URL?
  @objc public private(set) var title: String

  @objc public init(href: URL?, title: String) {
    self.title = title
    self.href = href
    super.init()
  }
}
