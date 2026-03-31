import Foundation

// MARK: - TPPOPDSEntryGroupAttributes (Swift port of TPPOPDSEntryGroupAttributes.m)

/// Swift reimplementation of the ObjC TPPOPDSEntryGroupAttributes model.
@objc(TPPOPDSEntryGroupAttributes)
public final class TPPOPDSEntryGroupAttributes: NSObject {

  /// May be nil if the group has no href.
  @objc public let href: URL?

  /// Always non-nil; throws if nil is passed.
  @objc public let title: String

  /// Designated initializer.
  /// - Parameters:
  ///   - href: The URL for the group (nilable).
  ///   - title: The title for the group. Must not be nil.
  @objc public init(href: URL?, title: String) {
    precondition(!title.isEmpty, "TPPOPDSEntryGroupAttributes requires a non-empty title")
    self.href = href
    self.title = title
    super.init()
  }
}
