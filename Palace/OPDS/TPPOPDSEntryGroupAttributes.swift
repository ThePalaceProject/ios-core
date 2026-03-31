import Foundation

@objc class TPPOPDSEntryGroupAttributes: NSObject {

  @objc private(set) var href: URL?
  @objc private(set) var title: String

  @objc init(href: URL?, title: String) {
    self.title = title
    self.href = href
    super.init()
  }
}
