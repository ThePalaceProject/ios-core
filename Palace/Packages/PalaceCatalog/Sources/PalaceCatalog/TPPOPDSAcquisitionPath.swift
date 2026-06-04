import Foundation

// MARK: - Content type constants
public let ContentTypeOPDSCatalog = "application/atom+xml;type=entry;profile=opds-catalog"
public let ContentTypeAdobeAdept = "application/vnd.adobe.adept+xml"
public let ContentTypeBearerToken = "application/vnd.librarysimplified.bearer-token+json"
public let ContentTypeEpubZip = "application/epub+zip"
public let ContentTypeFindaway = "application/vnd.librarysimplified.findaway.license+json"
public let ContentTypeOpenAccessAudiobook = "application/audiobook+json"
public let ContentTypeOpenAccessPDF = "application/pdf"
public let ContentTypeFeedbooksAudiobook = "application/audiobook+json;profile=\"http://www.feedbooks.com/audiobooks/access-restriction\""
public let ContentTypeOctetStream = "application/octet-stream"
public let ContentTypeOverdriveAudiobook = "application/vnd.overdrive.circulation.api+json;profile=audiobook"
public let ContentTypeOverdriveAudiobookActual = "application/json"
public let ContentTypeReadiumLCP = "application/vnd.readium.lcp.license.v1.0+json"
public let ContentTypeReadiumLCPPDF = "application/pdf"
public let ContentTypePDFLCP = "application/pdf+lcp"
public let ContentTypeAudiobookLCP = "application/audiobook+lcp"
public let ContentTypeAudiobookZip = "application/audiobook+zip"
public let ContentTypeBiblioboard = "application/json"
public let ContentTypeOPDSPublication = "application/opds-publication+json"

/// PP-4161: LibrarySimplified streaming-media profile of `text/html`. Books
/// whose only acquisition leaf carries this MIME render via the in-app
/// `Palace/ReaderStreaming/` WKWebView shell — no on-device asset, no DRM.
/// Reverses the PR #847 drop in `OPDS2PublicationExtended.toBook()`: once
/// this constant is in `supportedTypes()` + the OPDS-publication subtype
/// set, the generic `hasOpenablePath` filter passes streaming-media-only
/// publications through automatically.
public let ContentTypeStreamingHTML = "text/html;profile=http://librarysimplified.org/terms/profiles/streaming-media"

// MARK: - TPPOPDSAcquisitionPath

@objc public class TPPOPDSAcquisitionPath: NSObject {

  @objc public private(set) var relation: TPPOPDSAcquisitionRelation
  @objc public private(set) var types: [String]
  @objc public private(set) var url: URL

  @objc public init(relation: TPPOPDSAcquisitionRelation, types: [String], url: URL) {
    self.relation = relation
    self.types = types
    self.url = url
    super.init()
  }

  /// All content types this client knows how to acquire/render.
  ///
  /// Note: prior to PalaceCatalog extraction this method had `#if FEATURE_DRM_CONNECTOR`
  /// / `#if LCP` guards. With both DRM stacks always linked in modern builds those
  /// guards were always-true; we simplified to an unconditional list.
  ///
  /// The Adobe-cert-expired filter (originally `AdobeCertificate.defaultCertificate?.hasExpired`)
  /// reached for an app-target singleton and has been moved out — call sites that need
  /// to drop ContentTypeAdobeAdept on cert expiry should filter the returned set
  /// themselves (see `TPPOPDSAcquisitionPath+AppFilters.swift` in the app target).
  @objc public static func supportedTypes() -> Set<String> {
    return [
      ContentTypeOPDSCatalog,
      ContentTypeBearerToken,
      ContentTypeEpubZip,
      ContentTypeFindaway,
      ContentTypeOpenAccessAudiobook,
      ContentTypeOpenAccessPDF,
      ContentTypeFeedbooksAudiobook,
      ContentTypeOverdriveAudiobook,
      ContentTypeOctetStream,
      ContentTypeBiblioboard,
      ContentTypeAudiobookZip,
      ContentTypeOPDSPublication,
      ContentTypeAdobeAdept,
      ContentTypeReadiumLCP,
      ContentTypeAudiobookLCP,
      ContentTypeReadiumLCPPDF,
      ContentTypeStreamingHTML
    ]
  }

  @objc public static func supportedSubtypes(forType type: String) -> Set<String> {
    let subtypesForTypes: [String: Set<String>] = [
      ContentTypeOPDSCatalog: [
        ContentTypeAdobeAdept,
        ContentTypeBearerToken,
        ContentTypeFindaway,
        ContentTypeEpubZip,
        ContentTypeOpenAccessPDF,
        ContentTypeOpenAccessAudiobook,
        ContentTypeFeedbooksAudiobook,
        ContentTypeOverdriveAudiobook,
        ContentTypeOctetStream,
        ContentTypeReadiumLCP,
        ContentTypeAudiobookZip
      ],
      ContentTypeReadiumLCP: [
        ContentTypeEpubZip,
        ContentTypeAudiobookZip,
        ContentTypeAudiobookLCP,
        ContentTypeReadiumLCPPDF,
        ContentTypeReadiumLCP,
        ContentTypeOpenAccessAudiobook
      ],
      ContentTypeAdobeAdept: [ContentTypeEpubZip],
      ContentTypeBearerToken: [
        ContentTypeEpubZip,
        ContentTypeOpenAccessPDF,
        ContentTypeOpenAccessAudiobook
      ],
      ContentTypeOPDSPublication: [
        ContentTypeAdobeAdept,
        ContentTypeBearerToken,
        ContentTypeFindaway,
        ContentTypeEpubZip,
        ContentTypeOpenAccessPDF,
        ContentTypeOpenAccessAudiobook,
        ContentTypeFeedbooksAudiobook,
        ContentTypeOverdriveAudiobook,
        ContentTypeOctetStream,
        ContentTypeReadiumLCP,
        ContentTypeAudiobookZip,
        ContentTypeAudiobookLCP,
        ContentTypeStreamingHTML
      ]
    ]

    return subtypesForTypes[type] ?? []
  }

  @objc public static func audiobookTypes() -> Set<String> {
    return [
      ContentTypeFindaway,
      ContentTypeOpenAccessAudiobook,
      ContentTypeFeedbooksAudiobook,
      ContentTypeOverdriveAudiobook,
      ContentTypeAudiobookZip,
      ContentTypeAudiobookLCP
    ]
  }

  public override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? TPPOPDSAcquisitionPath else { return false }
    return relation == other.relation && types == other.types
  }

  public override var hash: Int {
    let prime = 31
    var result = 1
    result = prime * result + relation.rawValue
    result = prime * result + types.hashValue
    return result
  }

  @objc public static func supportedAcquisitionPaths(
    forAllowedTypes types: Set<String>,
    allowedRelations relations: UInt,
    acquisitions: [TPPOPDSAcquisition]
  ) -> [TPPOPDSAcquisitionPath] {
    var acquisitionPathSet = Set<TPPOPDSAcquisitionPath>()
    var acquisitionPaths = [TPPOPDSAcquisitionPath]()

    for acquisition in acquisitions {
      let containsType = types.contains(acquisition.type)
      let containsRelation = NYPLOPDSAcquisitionRelationSetContainsRelation(relations, acquisition.relation)

      guard containsType && containsRelation else { continue }

      if acquisition.indirectAcquisitions.isEmpty {
        let path = TPPOPDSAcquisitionPath(
          relation: acquisition.relation,
          types: [acquisition.type],
          url: acquisition.hrefURL
        )
        acquisitionPaths.append(path)
        continue
      }

      var supportedSubs = supportedSubtypes(forType: acquisition.type)
      supportedSubs = supportedSubs.intersection(types)

      for indirectAcquisition in acquisition.indirectAcquisitions {
        guard supportedSubs.contains(indirectAcquisition.type) else { continue }

        for mutableTypePath in mutableTypePaths(indirectAcquisition, types) {
          let typePath = [acquisition.type] + mutableTypePath
          let path = TPPOPDSAcquisitionPath(
            relation: acquisition.relation,
            types: typePath,
            url: acquisition.hrefURL
          )

          if !acquisitionPathSet.contains(path) {
            acquisitionPaths.append(path)
            acquisitionPathSet.insert(path)
          }
        }
      }
    }

    return acquisitionPaths
  }
}

private func mutableTypePaths(
  _ indirectAcquisition: TPPOPDSIndirectAcquisition,
  _ allowedTypes: Set<String>
) -> [[String]] {
  guard allowedTypes.contains(indirectAcquisition.type) else {
    return []
  }

  if indirectAcquisition.indirectAcquisitions.isEmpty {
    return [[indirectAcquisition.type]]
  }

  var supportedSubs = TPPOPDSAcquisitionPath.supportedSubtypes(forType: indirectAcquisition.type)
  supportedSubs = supportedSubs.intersection(allowedTypes)

  var results = [[String]]()
  for nested in indirectAcquisition.indirectAcquisitions {
    guard supportedSubs.contains(nested.type) else { continue }
    for typePath in mutableTypePaths(nested, allowedTypes) {
      results.append([indirectAcquisition.type] + typePath)
    }
  }

  return results
}
