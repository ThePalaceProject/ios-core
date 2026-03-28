import Foundation

// MARK: - Content Type Constants (Swift port of TPPOPDSAcquisitionPath.m)

/// Content type constants for OPDS acquisitions.
@objc public final class OPDSContentType: NSObject {
  @objc public static let opdsCatalog = "application/atom+xml;type=entry;profile=opds-catalog"
  @objc public static let adobeAdept = "application/vnd.adobe.adept+xml"
  @objc public static let bearerToken = "application/vnd.librarysimplified.bearer-token+json"
  @objc public static let epubZip = "application/epub+zip"
  @objc public static let findaway = "application/vnd.librarysimplified.findaway.license+json"
  @objc public static let openAccessAudiobook = "application/audiobook+json"
  @objc public static let openAccessPDF = "application/pdf"
  @objc public static let feedbooksAudiobook = "application/audiobook+json;profile=\"http://www.feedbooks.com/audiobooks/access-restriction\""
  @objc public static let octetStream = "application/octet-stream"
  @objc public static let overdriveAudiobook = "application/vnd.overdrive.circulation.api+json;profile=audiobook"
  @objc public static let overdriveAudiobookActual = "application/json"
  @objc public static let readiumLCP = "application/vnd.readium.lcp.license.v1.0+json"
  @objc public static let readiumLCPPDF = "application/pdf"
  @objc public static let pdfLCP = "application/pdf+lcp"
  @objc public static let audiobookLCP = "application/audiobook+lcp"
  @objc public static let audiobookZip = "application/audiobook+zip"
  @objc public static let biblioboard = "application/json"

  private override init() { super.init() }
}

// MARK: - Legacy C-style constant aliases (used by existing Swift callers)

public let ContentTypeOPDSCatalog = OPDSContentType.opdsCatalog
public let ContentTypeAdobeAdept = OPDSContentType.adobeAdept
public let ContentTypeBearerToken = OPDSContentType.bearerToken
public let ContentTypeEpubZip = OPDSContentType.epubZip
public let ContentTypeFindaway = OPDSContentType.findaway
public let ContentTypeOpenAccessAudiobook = OPDSContentType.openAccessAudiobook
public let ContentTypeOpenAccessPDF = OPDSContentType.openAccessPDF
public let ContentTypeFeedbooksAudiobook = OPDSContentType.feedbooksAudiobook
public let ContentTypeOctetStream = OPDSContentType.octetStream
public let ContentTypeOverdriveAudiobook = OPDSContentType.overdriveAudiobook
public let ContentTypeOverdriveAudiobookActual = OPDSContentType.overdriveAudiobookActual
public let ContentTypeReadiumLCP = OPDSContentType.readiumLCP
public let ContentTypeReadiumLCPPDF = OPDSContentType.readiumLCPPDF
public let ContentTypePDFLCP = OPDSContentType.pdfLCP
public let ContentTypeAudiobookLCP = OPDSContentType.audiobookLCP
public let ContentTypeAudiobookZip = OPDSContentType.audiobookZip
public let ContentTypeBiblioboard = OPDSContentType.biblioboard

// MARK: - TPPOPDSAcquisitionPath Swift Implementation

/// Swift reimplementation of the ObjC TPPOPDSAcquisitionPath model.
/// Represents a single path through an acquisition process.
@objc(TPPOPDSAcquisitionPath)
public final class TPPOPDSAcquisitionPath: NSObject {

  /// The relation of the initial acquisition step.
  @objc public let relation: TPPOPDSAcquisitionRelation

  /// The types of the path in acquisition order. Guaranteed count >= 1.
  @objc public let types: [String]

  /// The URL to fetch to begin processing the acquisition path.
  @objc public let url: URL

  /// Designated initializer.
  @objc public init(relation: TPPOPDSAcquisitionRelation, types: [String], url: URL) {
    self.relation = relation
    self.types = types
    self.url = url
    super.init()
  }

  // MARK: - Equality & Hash

  public override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? TPPOPDSAcquisitionPath else { return false }
    return relation == other.relation && types == other.types
  }

  public override var hash: Int {
    var result = 1
    let prime = 31
    result = prime &* result &+ relation.rawValue
    result = prime &* result &+ (types as NSArray).hash
    return result
  }

  // MARK: - Supported Types

  /// All types of acquisitions supported by the application.
  @objc public static func supportedTypes() -> Set<String> {
    var types: Set<String> = [
      OPDSContentType.opdsCatalog,
      OPDSContentType.bearerToken,
      OPDSContentType.epubZip,
      OPDSContentType.findaway,
      OPDSContentType.openAccessAudiobook,
      OPDSContentType.openAccessPDF,
      OPDSContentType.feedbooksAudiobook,
      OPDSContentType.overdriveAudiobook,
      OPDSContentType.octetStream,
      OPDSContentType.biblioboard,
      OPDSContentType.audiobookZip
    ]

    #if FEATURE_DRM_CONNECTOR
    types.insert(OPDSContentType.adobeAdept)
    if AdobeCertificate.defaultCertificate.hasExpired {
      types.remove(OPDSContentType.adobeAdept)
    }
    #endif

    #if LCP
    types.insert(OPDSContentType.readiumLCP)
    types.insert(OPDSContentType.audiobookLCP)
    types.insert(OPDSContentType.readiumLCPPDF)
    #endif

    return types
  }

  /// Audiobook content types.
  @objc public static func audiobookTypes() -> Set<String> {
    return [
      OPDSContentType.findaway,
      OPDSContentType.openAccessAudiobook,
      OPDSContentType.feedbooksAudiobook,
      OPDSContentType.overdriveAudiobook,
      OPDSContentType.audiobookZip,
      OPDSContentType.audiobookLCP
    ]
  }

  /// Returns supported subtypes for a given type.
  private static func supportedSubtypes(forType type: String) -> Set<String> {
    let subtypesMap: [String: Set<String>] = [
      OPDSContentType.opdsCatalog: [
        OPDSContentType.adobeAdept,
        OPDSContentType.bearerToken,
        OPDSContentType.findaway,
        OPDSContentType.epubZip,
        OPDSContentType.openAccessPDF,
        OPDSContentType.openAccessAudiobook,
        OPDSContentType.feedbooksAudiobook,
        OPDSContentType.overdriveAudiobook,
        OPDSContentType.octetStream,
        OPDSContentType.readiumLCP,
        OPDSContentType.audiobookZip
      ],
      OPDSContentType.readiumLCP: [
        OPDSContentType.epubZip,
        OPDSContentType.audiobookZip,
        OPDSContentType.audiobookLCP,
        OPDSContentType.readiumLCPPDF,
        OPDSContentType.readiumLCP,
        OPDSContentType.openAccessAudiobook
      ],
      OPDSContentType.adobeAdept: [OPDSContentType.epubZip],
      OPDSContentType.bearerToken: [
        OPDSContentType.epubZip,
        OPDSContentType.openAccessPDF,
        OPDSContentType.openAccessAudiobook
      ]
    ]
    return subtypesMap[type] ?? []
  }

  // MARK: - Path Resolution

  /// Recursively builds type paths from an indirect acquisition.
  private static func mutableTypePaths(
    _ indirectAcquisition: TPPOPDSIndirectAcquisition,
    allowedTypes: Set<String>
  ) -> [[String]] {
    guard allowedTypes.contains(indirectAcquisition.type) else {
      return []
    }

    if indirectAcquisition.indirectAcquisitions.isEmpty {
      return [[indirectAcquisition.type]]
    }

    let supportedSubs = supportedSubtypes(forType: indirectAcquisition.type).intersection(allowedTypes)
    var results: [[String]] = []

    for nested in indirectAcquisition.indirectAcquisitions {
      guard supportedSubs.contains(nested.type) else { continue }
      for var typePath in mutableTypePaths(nested, allowedTypes: allowedTypes) {
        typePath.insert(indirectAcquisition.type, at: 0)
        results.append(typePath)
      }
    }

    return results
  }

  /// Finds supported acquisition paths given allowed types, relations, and acquisitions.
  @objc public static func supportedAcquisitionPaths(
    forAllowedTypes types: Set<String>,
    allowedRelations relations: TPPOPDSAcquisitionRelationSet,
    acquisitions: [TPPOPDSAcquisition]
  ) -> [TPPOPDSAcquisitionPath] {
    var pathSet = Set<Int>()  // hash-based deduplication
    var paths: [TPPOPDSAcquisitionPath] = []

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
        paths.append(path)
        continue
      }

      let supportedSubs = supportedSubtypes(forType: acquisition.type).intersection(types)

      for indirect in acquisition.indirectAcquisitions {
        guard supportedSubs.contains(indirect.type) else { continue }

        for var typePath in mutableTypePaths(indirect, allowedTypes: types) {
          typePath.insert(acquisition.type, at: 0)

          let path = TPPOPDSAcquisitionPath(
            relation: acquisition.relation,
            types: typePath,
            url: acquisition.hrefURL
          )

          let pathHash = path.hash
          if !pathSet.contains(pathHash) {
            paths.append(path)
            pathSet.insert(pathHash)
          }
        }
      }
    }

    return paths
  }
}
