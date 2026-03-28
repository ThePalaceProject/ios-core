import Foundation

// MARK: - TPPOPDSCategory (Swift port of TPPOPDSCategory.m)

/// Swift reimplementation of the ObjC TPPOPDSCategory model.
/// Must remain @objc-accessible since the entire app references this type.
@objc(TPPOPDSCategory)
public final class TPPOPDSCategory: NSObject {

  @objc public let term: String
  @objc public let label: String?
  @objc public let scheme: URL?

  @objc public init(term: String, label: String?, scheme: URL?) {
    precondition(!term.isEmpty, "TPPOPDSCategory requires a non-empty term")
    self.term = term
    self.label = label
    self.scheme = scheme
    super.init()
  }

  /// Convenience factory matching the ObjC `+categoryWithTerm:label:scheme:` method.
  @objc public static func category(withTerm term: String, label: String?, scheme: URL?) -> TPPOPDSCategory {
    return TPPOPDSCategory(term: term, label: label, scheme: scheme)
  }
}
