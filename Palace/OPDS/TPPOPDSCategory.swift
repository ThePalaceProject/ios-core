import Foundation

@objc class TPPOPDSCategory: NSObject {

  @objc private(set) var term: String
  @objc private(set) var label: String?
  @objc private(set) var scheme: URL?

  @objc init(term: String, label: String?, scheme: URL?) {
    self.term = term
    self.label = label
    self.scheme = scheme
    super.init()
  }

  @objc static func category(withTerm term: String, label: String?, scheme: URL?) -> TPPOPDSCategory {
    return TPPOPDSCategory(term: term, label: label, scheme: scheme)
  }
}
