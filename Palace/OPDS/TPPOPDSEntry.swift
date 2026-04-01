import Foundation

@objc class TPPOPDSEntry: NSObject {

  @objc private(set) var acquisitions: [TPPOPDSAcquisition] = []
  @objc private(set) var alternativeHeadline: String?
  @objc private(set) var authorStrings: [String] = []
  @objc private(set) var authorLinks: [TPPOPDSLink] = []
  @objc private(set) var seriesLink: TPPOPDSLink?
  @objc private(set) var categories: [TPPOPDSCategory] = []
  @objc private(set) var identifier: String = ""
  @objc private(set) var links: [TPPOPDSLink] = []
  @objc private(set) var annotations: TPPOPDSLink?
  @objc private(set) var alternate: TPPOPDSLink?
  @objc private(set) var relatedWorks: TPPOPDSLink?
  @objc private(set) var previewLink: TPPOPDSAcquisition?
  @objc private(set) var analytics: URL?
  @objc private(set) var providerName: String?
  @objc private(set) var published: Date?
  @objc private(set) var publisher: String?
  @objc private(set) var summary: String?
  @objc private(set) var title: String = ""
  @objc private(set) var updated: Date = Date()
  @objc private(set) var contributors: [String: [String]]?
  @objc private(set) var timeTrackingLink: TPPOPDSLink?
  @objc private(set) var duration: String?

  @objc var groupAttributes: TPPOPDSEntryGroupAttributes? {
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

  @objc init?(xml entryXML: TPPXML) {
    super.init()

    alternativeHeadline = entryXML.firstChild(withName: "alternativeHeadline")?.value

    parseAuthors(from: entryXML)
    parseContributors(from: entryXML)
    parseCategories(from: entryXML)

    guard parseIdentifier(from: entryXML) else { return nil }

    providerName = (entryXML.firstChild(withName: "distribution")?.attributes as? [String: String])?["bibframe:ProviderName"]

    parseLinks(from: entryXML)

    if let dateString = entryXML.firstChild(withName: "issued")?.value {
      published = NSDate.date(withISO8601DateString: dateString) as Date?
    }

    publisher = entryXML.firstChild(withName: "publisher")?.value
    summary = entryXML.firstChild(withName: "summary")?.value.stringByDecodingHTMLEntities

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
      let role = (contributorNode.attributes as? [String: String])?["opf:role"] ?? ""
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
        if let acquisition = TPPOPDSAcquisition.acquisition(withLinkXML: linkXML) {
          let mimeType = acquisition.type
          let isEpubPreview = mimeType == "application/epub+zip"
          let isPalaceMarketplace = providerName == "Palace Marketplace"

          if isPalaceMarketplace {
            if isEpubPreview && previewLink == nil {
              previewLink = acquisition
            }
          } else if previewLink == nil {
            previewLink = acquisition
          }
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
