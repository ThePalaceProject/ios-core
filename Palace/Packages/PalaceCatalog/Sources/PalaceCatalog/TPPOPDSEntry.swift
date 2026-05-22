import Foundation
import PalaceLogging

@objc public class TPPOPDSEntry: NSObject {

  @objc public private(set) var acquisitions: [TPPOPDSAcquisition] = []
  @objc public private(set) var alternativeHeadline: String?
  @objc public private(set) var authorStrings: [String] = []
  @objc public private(set) var authorLinks: [TPPOPDSLink] = []
  @objc public private(set) var seriesLink: TPPOPDSLink?
  @objc public private(set) var categories: [TPPOPDSCategory] = []
  @objc public private(set) var identifier: String = ""
  @objc public private(set) var links: [TPPOPDSLink] = []
  @objc public private(set) var annotations: TPPOPDSLink?
  @objc public private(set) var alternate: TPPOPDSLink?
  @objc public private(set) var relatedWorks: TPPOPDSLink?
  @objc public private(set) var previewLink: TPPOPDSAcquisition?
  @objc public private(set) var analytics: URL?
  @objc public private(set) var providerName: String?
  @objc public private(set) var published: Date?
  @objc public private(set) var publisher: String?
  @objc public private(set) var summary: String?
  @objc public private(set) var title: String = ""
  @objc public private(set) var updated: Date = Date()
  @objc public private(set) var contributors: [String: [String]]?
  @objc public private(set) var timeTrackingLink: TPPOPDSLink?
  @objc public private(set) var duration: String?

  /// Patron audience ("Adult", "Young Adult", "Children", ...). Sourced from
  /// the `<category scheme="http://schema.org/audience">` entry — distinct
  /// from the genre categories surfaced via `categories`.
  @objc public private(set) var audience: String?

  /// BCP-47 / ISO 639 language code from `<dcterms:language>`.
  @objc public private(set) var language: String?

  @objc public var groupAttributes: TPPOPDSEntryGroupAttributes? {
    for link in links {
      if link.rel == TPPOPDSRelationGroup {
        guard let title = (link.attributes as? [String: String])?["title"] else {
          Log.log("Ignoring group link without required 'title' attribute.")
          continue
        }
        let hrefString = (link.attributes as? [String: String])?["href"]
        let href = hrefString.flatMap { URL(string: $0) }
        return TPPOPDSEntryGroupAttributes(href: href, title: title)
      }
    }
    return nil
  }

  @objc public init?(xml entryXML: TPPXML) {
    super.init()

    alternativeHeadline = entryXML.firstChild(withName: "alternativeHeadline")?.value

    parseAuthors(from: entryXML)
    parseContributors(from: entryXML)
    parseCategories(from: entryXML)

    guard parseIdentifier(from: entryXML) else { return nil }

    providerName = (entryXML.firstChild(withName: "distribution")?.attributes as? [String: String])?["bibframe:ProviderName"]

    parseLinks(from: entryXML)

    // Atom (RFC 4287) uses <published> for the canonical publication date.
    // Legacy/Dublin Core feeds use <issued>. Prefer <published>, fall back
    // to <issued>, else leave nil.
    if let dateString = entryXML.firstChild(withName: "published")?.value
        ?? entryXML.firstChild(withName: "issued")?.value {
      published = NSDate.date(withISO8601DateString: dateString) as Date?
    }

    publisher = entryXML.firstChild(withName: "publisher")?.value
    summary = entryXML.firstChild(withName: "summary")?.value.stringByDecodingHTMLEntities

    // Audience is published as `<category scheme="schema.org/audience">`
    // extract the label/term so the detail view can render it as its own row
    // independent from the genre category list.
    audience = categories.first(where: {
      $0.scheme?.absoluteString == "http://schema.org/audience"
    }).map { $0.label ?? $0.term }

    // `<dcterms:language>` is normally namespace-stripped to
    // `language` (TPPXML sets shouldProcessNamespaces=true); legacy feeds
    // that omit the `xmlns:dcterms` declaration leave the literal prefix in
    // place. Read either, prefer the unprefixed form. Same defensive pattern
    // as the role/opf:role lookup in parseContributors (PP-4230).
    language = entryXML.firstChild(withName: "language")?.value
      ?? entryXML.firstChild(withName: "dcterms:language")?.value

    guard parseTitle(from: entryXML) else { return nil }
    guard parseUpdatedDate(from: entryXML) else { return nil }
    parseSeries(from: entryXML)
  }

  // MARK: - Private parsing methods

  private func parseAuthors(from entryXML: TPPXML) {
    var authorStrs = [String]()
    var authorLnks = [TPPOPDSLink]()

    if let durationXML = entryXML.childrenWithName("duration").first {
      duration = durationXML.value
    }

    for authorXML in entryXML.childrenWithName("author") {
      guard let nameXML = authorXML.firstChild(withName: "name") else {
        Log.log("'author' element missing required 'name' element. Ignoring malformed 'author' element.")
        continue
      }
      authorStrs.append(nameXML.value)

      if let authorLinkXML = authorXML.firstChild(withName: "link"),
         let link = TPPOPDSLink(xml: authorLinkXML),
         link.rel == "contributor" {
        authorLnks.append(link)
      }
    }

    authorStrings = authorStrs
    authorLinks = authorLnks
  }

  private func parseContributors(from entryXML: TPPXML) {
    var contribs = [String: [String]]()

    for contributorNode in entryXML.childrenWithName("contributor") {
      // Foundation's XMLParser with shouldProcessNamespaces=true
      // strips the `opf:` prefix from attribute names when the feed declares
      // `xmlns:opf` (real-world feeds do — A1QA, Bibliotheca, BiblioBoard,
      // ODL providers). The unprefixed `"role"` is the canonical key in that
      // case; legacy feeds without the namespace declaration keep the literal
      // `"opf:role"`. Read either, prefer the unprefixed form.
      let attrs = (contributorNode.attributes as? [String: String]) ?? [:]
      let role = attrs["role"] ?? attrs["opf:role"] ?? ""
      if let name = contributorNode.firstChild(withName: "name")?.value.stringByDecodingHTMLEntities {
        contribs[role, default: []].append(name)
      }
    }

    if !contribs.isEmpty {
      contributors = contribs
    }
  }

  private func parseCategories(from entryXML: TPPXML) {
    var cats = [TPPOPDSCategory]()
    for categoryXML in entryXML.childrenWithName("category") {
      let attrs = categoryXML.attributes as? [String: String] ?? [:]
      guard let term = attrs["term"] else {
        Log.log("Category missing required 'term'.")
        continue
      }
      let scheme = attrs["scheme"].flatMap { URL(string: $0) }
      cats.append(TPPOPDSCategory.category(withTerm: term, label: attrs["label"], scheme: scheme))
    }
    categories = cats
  }

  private func parseIdentifier(from entryXML: TPPXML) -> Bool {
    guard let id = entryXML.firstChild(withName: "id")?.value else {
      Log.log("Missing required 'id' element.")
      return false
    }
    identifier = id
    return true
  }

  private func parseLinks(from entryXML: TPPXML) {
    var mutableLinks = [TPPOPDSLink]()
    var mutableAcquisitions = [TPPOPDSAcquisition]()

    for linkXML in entryXML.childrenWithName("link") {
      let rel = (linkXML.attributes as? [String: String])?["rel"] ?? ""

      if rel.contains(TPPOPDSRelationAcquisition) {
        if let acquisition = TPPOPDSAcquisition.acquisition(withLinkXML: linkXML) {
          mutableAcquisitions.append(acquisition)
          continue
        }
      }

      if rel.contains(TPPOPDSRelationPreview) {
        if let acquisition = TPPOPDSAcquisition.acquisition(withLinkXML: linkXML),
           previewLink == nil {
          previewLink = acquisition
        }
      }

      guard let link = TPPOPDSLink(xml: linkXML) else {
        Log.log("Ignoring malformed 'link' element.")
        continue
      }

      if link.rel == "http://www.w3.org/ns/oa#annotationService" {
        annotations = link
      } else if link.rel == "alternate" {
        alternate = link
        analytics = URL(string: link.href.absoluteString.replacingOccurrences(of: "/works/", with: "/analytics/"))
      } else if link.rel == "related" {
        relatedWorks = link
      } else if link.rel == TPPOPDSRelationTimeTrackingLink {
        timeTrackingLink = link
      } else {
        mutableLinks.append(link)
      }
    }

    acquisitions = mutableAcquisitions
    links = mutableLinks
  }

  private func parseTitle(from entryXML: TPPXML) -> Bool {
    guard let t = entryXML.firstChild(withName: "title")?.value else {
      Log.log("Missing required 'title' element.")
      return false
    }
    title = t
    return true
  }

  private func parseUpdatedDate(from entryXML: TPPXML) -> Bool {
    guard let updatedString = entryXML.firstChild(withName: "updated")?.value else {
      Log.log("Missing required 'updated' element.")
      return false
    }
    guard let date = NSDate.date(withRFC3339String: updatedString) as Date? else {
      Log.log("Element 'updated' does not contain an RFC 3339 date.")
      return false
    }
    updated = date
    return true
  }

  private func parseSeries(from entryXML: TPPXML) {
    if let seriesXML = entryXML.firstChild(withName: "Series"),
       let linkXML = seriesXML.firstChild(withName: "link") {
      seriesLink = TPPOPDSLink(xml: linkXML)
    }
  }
}
