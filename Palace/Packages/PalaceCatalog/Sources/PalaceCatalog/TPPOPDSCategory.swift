import Foundation

@objc public class TPPOPDSCategory: NSObject {

  @objc public private(set) var term: String
  @objc public private(set) var label: String?
  @objc public private(set) var scheme: URL?

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
