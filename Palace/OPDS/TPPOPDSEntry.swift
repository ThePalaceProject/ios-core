import Foundation

// MARK: - TPPOPDSEntry (Swift port of TPPOPDSEntry.m)

/// Swift reimplementation of the ObjC TPPOPDSEntry model.
/// Parses an OPDS entry from XML.
@objc(TPPOPDSEntry)
public final class TPPOPDSEntry: NSObject {

  @objc public let acquisitions: [TPPOPDSAcquisition]
  @objc public let alternativeHeadline: String?
  @objc public let authorStrings: [String]
  @objc public let authorLinks: [TPPOPDSLink]
  @objc public let seriesLink: TPPOPDSLink?
  @objc public let categories: [TPPOPDSCategory]
  @objc public let identifier: String
  @objc public let links: [TPPOPDSLink]
  @objc public let annotations: TPPOPDSLink?
  @objc public let alternate: TPPOPDSLink?
  @objc public let relatedWorks: TPPOPDSLink?
  @objc public let previewLink: TPPOPDSAcquisition?
  @objc public let analytics: URL?
  @objc public let providerName: String?
  @objc public let published: Date?
  @objc public let publisher: String?
  @objc public let summary: String?
  @objc public let title: String
  @objc public let updated: Date
  @objc public let contributors: NSDictionary?
  @objc public let timeTrackingLink: TPPOPDSLink?
  @objc public let duration: String?

  /// Designated initializer. Returns `nil` if the XML is missing required fields.
  @objc init?(xml entryXML: TPPXML) {
    // alternativeHeadline
    self.alternativeHeadline = entryXML.firstChild(withName: "alternativeHeadline")?.value

    // duration
    self.duration = entryXML.firstChild(withName: "duration")?.value

    // authors
    var authorStrs: [String] = []
    var authorLnks: [TPPOPDSLink] = []
    for authorObj in entryXML.children(withName: "author") {
      guard let authorXML = authorObj as? TPPXML else { continue }
      guard let nameXML = authorXML.firstChild(withName: "name") else {
        Log.warn(#file, "'author' element missing required 'name' element. Ignoring malformed 'author' element.")
        continue
      }
      authorStrs.append(nameXML.value)
      if let linkXML = authorXML.firstChild(withName: "link"),
         let link = TPPOPDSLink(xml: linkXML),
         link.rel == "contributor" {
        authorLnks.append(link)
      }
    }
    self.authorStrings = authorStrs
    self.authorLinks = authorLnks

    // contributors
    var contribs: [String: [String]] = [:]
    for contributorObj in entryXML.children(withName: "contributor") {
      guard let contributorXML = contributorObj as? TPPXML else { continue }
      let role = contributorXML.attributes["opf:role"] as? String ?? ""
      if let name = contributorXML.firstChild(withName: "name")?.value.stringByDecodingHTMLEntities {
        contribs[role, default: []].append(name)
      }
    }
    self.contributors = contribs.isEmpty ? nil : contribs as NSDictionary

    // categories
    var cats: [TPPOPDSCategory] = []
    for categoryObj in entryXML.children(withName: "category") {
      guard let categoryXML = categoryObj as? TPPXML else { continue }
      guard let term = categoryXML.attributes["term"] as? String else {
        Log.warn(#file, "Category missing required 'term'.")
        continue
      }
      let schemeString = categoryXML.attributes["scheme"] as? String
      let scheme = schemeString.flatMap { URL(string: $0) }
      let label = categoryXML.attributes["label"] as? String
      cats.append(TPPOPDSCategory(term: term, label: label, scheme: scheme))
    }
    self.categories = cats

    // identifier (required)
    guard let identifierValue = entryXML.firstChild(withName: "id")?.value else {
      Log.warn(#file, "Missing required 'id' element.")
      return nil
    }
    self.identifier = identifierValue

    // providerName
    self.providerName = (entryXML.firstChild(withName: "distribution")?.attributes["bibframe:ProviderName"]) as? String

    // published
    if let dateString = entryXML.firstChild(withName: "issued")?.value {
      self.published = NSDate(iso8601DateString: dateString) as Date?
    } else {
      self.published = nil
    }

    // publisher
    self.publisher = entryXML.firstChild(withName: "publisher")?.value

    // summary
    self.summary = entryXML.firstChild(withName: "summary")?.value.stringByDecodingHTMLEntities

    // title (required)
    guard let titleValue = entryXML.firstChild(withName: "title")?.value else {
      Log.warn(#file, "Missing required 'title' element.")
      return nil
    }
    self.title = titleValue

    // updated (required)
    guard let updatedString = entryXML.firstChild(withName: "updated")?.value,
          let updatedDate = NSDate(rfc3339String: updatedString) as Date? else {
      Log.warn(#file, "Missing or invalid required 'updated' element.")
      return nil
    }
    self.updated = updatedDate

    // links and acquisitions
    var mutableLinks: [TPPOPDSLink] = []
    var mutableAcquisitions: [TPPOPDSAcquisition] = []
    var annotationsLink: TPPOPDSLink?
    var alternateLink: TPPOPDSLink?
    var relatedWorksLink: TPPOPDSLink?
    var analyticsURL: URL?
    var preview: TPPOPDSAcquisition?
    var timeTracking: TPPOPDSLink?

    let acquisitionRelStr = TPPOPDSRelationAcquisition
    let previewRelStr = TPPOPDSRelationPreview
    let timeTrackingRelStr = TPPOPDSRelationTimeTrackingLink

    for linkObj in entryXML.children(withName: "link") {
      guard let linkXML = linkObj as? TPPXML else { continue }
      let rel = linkXML.attributes["rel"] as? String ?? ""

      // Check acquisition links
      if rel.contains(acquisitionRelStr) {
        if let acq = TPPOPDSAcquisition(linkXML: linkXML) {
          mutableAcquisitions.append(acq)
          continue
        }
      }

      // Check preview links
      if rel.contains(previewRelStr) {
        if let acq = TPPOPDSAcquisition(linkXML: linkXML) {
          let mimeType = acq.type
          let isEpubPreview = mimeType == "application/epub+zip"
          let isPalaceMarketplace = self.providerName == "Palace Marketplace"

          if isPalaceMarketplace {
            if isEpubPreview && preview == nil {
              preview = acq
            }
          } else if preview == nil {
            preview = acq
          }
        }
      }

      guard let link = TPPOPDSLink(xml: linkXML) else {
        Log.warn(#file, "Ignoring malformed 'link' element.")
        continue
      }

      if link.rel == "http://www.w3.org/ns/oa#annotationService" {
        annotationsLink = link
      } else if link.rel == "alternate" {
        alternateLink = link
        let analyticsString = link.href.absoluteString.replacingOccurrences(of: "/works/", with: "/analytics/")
        analyticsURL = URL(string: analyticsString)
      } else if link.rel == "related" {
        relatedWorksLink = link
      } else if link.rel == timeTrackingRelStr {
        timeTracking = link
      } else {
        mutableLinks.append(link)
      }
    }

    self.acquisitions = mutableAcquisitions
    self.links = mutableLinks
    self.annotations = annotationsLink
    self.alternate = alternateLink
    self.relatedWorks = relatedWorksLink
    self.previewLink = preview
    self.analytics = analyticsURL
    self.timeTrackingLink = timeTracking

    // seriesLink
    if let seriesXML = entryXML.firstChild(withName: "Series"),
       let seriesLinkXML = seriesXML.firstChild(withName: "link") {
      self.seriesLink = TPPOPDSLink(xml: seriesLinkXML)
    } else {
      self.seriesLink = nil
    }

    super.init()
  }

  /// Computes group attributes from the entry's links (lazy in ObjC, computed here).
  @objc public var groupAttributes: TPPOPDSEntryGroupAttributes? {
    for link in links {
      if link.rel == TPPOPDSRelationGroup {
        guard let title = link.attributes["title"] as? String else {
          Log.warn(#file, "Ignoring group link without required 'title' attribute.")
          continue
        }
        let hrefString = link.attributes["href"] as? String
        let href = hrefString.flatMap { URL(string: $0) }
        return TPPOPDSEntryGroupAttributes(href: href, title: title)
      }
    }
    return nil
  }
}
