import Foundation

// @unchecked Sendable invariant: every stored property is `private(set)` and
// assigned exactly once in `init`; instances are never mutated afterward.
// `entries` is typed `[Any]` only for Objective-C bridging — it holds the
// value-immutable OPDS entry objects, so `@unchecked` is required (the compiler
// cannot prove `[Any]` Sendable) but the contents are in fact safe to share.
@objc public final class TPPOPDSGroup: NSObject, @unchecked Sendable {

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
