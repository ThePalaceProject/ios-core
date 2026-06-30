import Foundation

// Sendable: `final` + immutable `let` Sendable value-type stored properties.
@objc public final class TPPOPDSCategory: NSObject, Sendable {

  @objc public let term: String
  @objc public let label: String?
  @objc public let scheme: URL?

  @objc public init(term: String, label: String?, scheme: URL?) {
    self.term = term
    self.label = label
    self.scheme = scheme
    super.init()
  }

  @objc public static func category(withTerm term: String, label: String?, scheme: URL?) -> TPPOPDSCategory {
    return TPPOPDSCategory(term: term, label: label, scheme: scheme)
  }
}
