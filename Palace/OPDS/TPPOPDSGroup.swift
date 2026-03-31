import Foundation

@objc class TPPOPDSGroup: NSObject {

  @objc private(set) var entries: [Any]
  @objc private(set) var href: URL
  @objc private(set) var title: String

  @objc init(entries: [Any], href: URL, title: String) {
    self.entries = entries
    self.href = href
    self.title = title
    super.init()
  }
}
