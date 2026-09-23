import Foundation

// Sendable: `final` + immutable `let` Sendable value-type stored properties.
@objc public final class TPPOPDSEntryGroupAttributes: NSObject, Sendable {

  @objc public let href: URL?
  @objc public let title: String

  @objc public init(href: URL?, title: String) {
    self.title = title
    self.href = href
    super.init()
  }
}
