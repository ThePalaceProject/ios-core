import Foundation
import PalaceLogging

@objc public enum TPPOPDSFeedType: Int {
  case invalid
  case acquisitionGrouped
  case acquisitionUngrouped
  case navigation
}

// @unchecked Sendable invariant: every stored property is `private(set)` and is
// assigned only during `init?(xml:)`; no method mutates an instance afterward.
// `type` is computed eagerly during init (see `computeType(from:)`) instead of
// via a post-init lazy cache, so there is no mutable-after-init state to race on.
// `@unchecked` (vs checked) is required because `licensor` is an `NSDictionary?`,
// which the compiler cannot prove Sendable; it is an immutable dictionary built
// locally in init and never re-exposed for mutation.
@objc public final class TPPOPDSFeed: NSObject, @unchecked Sendable {

  @objc public private(set) var entries: [TPPOPDSEntry] = []
  @objc public private(set) var identifier: String?
  @objc public private(set) var links: [TPPOPDSLink] = []
  @objc public private(set) var title: String?
  @objc public private(set) var updated: Date?
  @objc public private(set) var licensor: NSDictionary?
  @objc public private(set) var authorizationIdentifier: String?

  /// Feed type, derived from `entries`. Computed once during init and never
  /// mutated afterward (the previous lazy `_type`/`typeIsCached` cache mutated
  /// on first access, which was not safe for concurrent reads).
  @objc public private(set) var type: TPPOPDSFeedType = .invalid

  private static func computeType(from entries: [TPPOPDSEntry]) -> TPPOPDSFeedType {
    guard !entries.isEmpty else { return .acquisitionUngrouped }

    let provisionalType = typeImplied(by: entries[0])
    if provisionalType == .invalid { return .invalid }

    for i in 1..<entries.count {
      if typeImplied(by: entries[i]) != provisionalType { return .invalid }
    }

    return provisionalType
  }

  @objc public init?(xml feedXML: TPPXML?) {
    super.init()

    guard let feedXML = feedXML else { return nil }

    // Sometimes we get back JUST an entry
    if feedXML.name == "entry" {
      guard let entry = TPPOPDSEntry(xml: feedXML) else {
        Log.log("Error creating single OPDS entry from feed.")
        return nil
      }
      entries = [entry]
      type = Self.computeType(from: entries)
      return
    }

    guard let id = feedXML.firstChild(withName: "id")?.value else {
      Log.log("Missing required 'id' element.")
      return nil
    }
    identifier = id

    var parsedLinks = [TPPOPDSLink]()
    for linkXML in feedXML.childrenWithName("link") {
      guard let link = TPPOPDSLink(xml: linkXML) else {
        Log.log("Ignoring malformed 'link' element.")
        continue
      }
      parsedLinks.append(link)
    }
    links = parsedLinks

    guard let t = feedXML.firstChild(withName: "title")?.value else {
      Log.log("Missing required 'title' element.")
      return nil
    }
    title = t

    guard let updatedString = feedXML.firstChild(withName: "updated")?.value else {
      Log.log("Missing required 'updated' element.")
      return nil
    }
    guard let updatedDate = NSDate.date(withRFC3339String: updatedString) as Date? else {
      Log.log("Element 'updated' does not contain an RFC 3339 date.")
      return nil
    }
    updated = updatedDate

    var parsedEntries = [TPPOPDSEntry]()
    for entryXML in feedXML.childrenWithName("entry") {
      guard let entry = TPPOPDSEntry(xml: entryXML) else {
        Log.log("Ignoring malformed 'entry' element.")
        continue
      }
      parsedEntries.append(entry)
    }
    entries = parsedEntries
    type = Self.computeType(from: entries)

    if let patronXML = feedXML.firstChild(withName: "patron"),
       let attrs = patronXML.attributes as? [String: String],
       !attrs.isEmpty {
      authorizationIdentifier = attrs["simplified:authorizationIdentifier"]
    }

    if let licensorXML = feedXML.firstChild(withName: "licensor"),
       let attrs = licensorXML.attributes as? [String: String],
       !attrs.isEmpty {
      if let vendor = attrs["drm:vendor"],
         let tokenXML = licensorXML.firstChild(withName: "clientToken") {
        let clientToken = tokenXML.value
        licensor = ["vendor": vendor, "clientToken": clientToken] as NSDictionary
      } else {
        Log.log("Licensor not saved. Error parsing clientToken into XML.")
      }
    } else {
      Log.log("No Licensor found in OPDS feed. Moving on.")
    }
  }

  fileprivate static func typeImplied(by entry: TPPOPDSEntry) -> TPPOPDSFeedType {
    var entryIsGrouped = false
    var entryIsCatalogEntry = !entry.acquisitions.isEmpty

    for link in entry.links {
      if let rel = link.rel {
        if rel.hasPrefix("http://opds-spec.org/acquisition") {
          entryIsCatalogEntry = true
        } else if rel == TPPOPDSRelationGroup {
          entryIsGrouped = true
        }
      }
    }

    if entryIsGrouped && !entryIsCatalogEntry {
      return .invalid
    }

    return entryIsCatalogEntry
      ? (entryIsGrouped ? .acquisitionGrouped : .acquisitionUngrouped)
      : .navigation
  }
}
