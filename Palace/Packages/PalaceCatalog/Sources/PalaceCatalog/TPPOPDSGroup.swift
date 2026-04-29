import Foundation

@objc public class TPPOPDSGroup: NSObject {

  @objc public private(set) var entries: [Any]
  @objc public private(set) var href: URL
  @objc public private(set) var title: String

  @objc public init(entries: [Any], href: URL, title: String) {
    self.entries = entries
    self.href = href
    self.title = title
    super.init()
  }
}
