import Foundation

// MARK: - TPPOPDSGroup (Swift port of TPPOPDSGroup.m)

/// Swift reimplementation of the ObjC TPPOPDSGroup model.
/// Contains a list of OPDS entries grouped under a title with an href.
@objc(TPPOPDSGroupSwift)
public final class TPPOPDSGroupSwift: NSObject {

  @objc public let entries: [TPPOPDSEntry]
  @objc public let href: URL
  @objc public let title: String

  /// Designated initializer.
  /// - Parameters:
  ///   - entries: Array of `TPPOPDSEntry` objects. Must not be empty-checked at this level
  ///             but all elements must be `TPPOPDSEntry` instances.
  ///   - href: The URL for the group.
  ///   - title: The title for the group.
  @objc public init(entries: [TPPOPDSEntry], href: URL, title: String) {
    self.entries = entries
    self.href = href
    self.title = title
    super.init()
  }
}
