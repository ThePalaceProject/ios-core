import Foundation

// MARK: - Content type constants
let ContentTypeOPDSCatalog = "application/atom+xml;type=entry;profile=opds-catalog"
let ContentTypeAdobeAdept = "application/vnd.adobe.adept+xml"
let ContentTypeBearerToken = "application/vnd.librarysimplified.bearer-token+json"
let ContentTypeEpubZip = "application/epub+zip"
let ContentTypeFindaway = "application/vnd.librarysimplified.findaway.license+json"
let ContentTypeOpenAccessAudiobook = "application/audiobook+json"
let ContentTypeOpenAccessPDF = "application/pdf"
let ContentTypeFeedbooksAudiobook = "application/audiobook+json;profile=\"http://www.feedbooks.com/audiobooks/access-restriction\""
let ContentTypeOctetStream = "application/octet-stream"
let ContentTypeOverdriveAudiobook = "application/vnd.overdrive.circulation.api+json;profile=audiobook"
let ContentTypeOverdriveAudiobookActual = "application/json"
let ContentTypeReadiumLCP = "application/vnd.readium.lcp.license.v1.0+json"
let ContentTypeReadiumLCPPDF = "application/pdf"
let ContentTypePDFLCP = "application/pdf+lcp"
let ContentTypeAudiobookLCP = "application/audiobook+lcp"
let ContentTypeAudiobookZip = "application/audiobook+zip"
let ContentTypeBiblioboard = "application/json"

// MARK: - TPPOPDSAcquisitionPath

@objc class TPPOPDSAcquisitionPath: NSObject {

  @objc private(set) var relation: TPPOPDSAcquisitionRelation
  @objc private(set) var types: [String]
  @objc private(set) var url: URL

  @objc init(relation: TPPOPDSAcquisitionRelation, types: [String], url: URL) {
    self.relation = relation
    self.types = types
    self.url = url
    super.init()
  }

  @objc static func supportedTypes() -> Set<String> {
    var types: Set<String> = [
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
      ContentTypeAudiobookZip
    ]

    #if FEATURE_DRM_CONNECTOR
    types.insert(ContentTypeAdobeAdept)
    #endif

    #if LCP
    types.insert(ContentTypeReadiumLCP)
    types.insert(ContentTypeAudiobookLCP)
    types.insert(ContentTypeReadiumLCPPDF)
    #endif

    #if FEATURE_DRM_CONNECTOR
    if AdobeCertificate.defaultCertificate?.hasExpired == true {
      types.remove(ContentTypeAdobeAdept)
    }
    #endif

    return types
  }

  @objc static func supportedSubtypes(forType type: String) -> Set<String> {
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
      ]
    ]

    return subtypesForTypes[type] ?? []
  }

  @objc static func audiobookTypes() -> Set<String> {
    return [
      ContentTypeFindaway,
      ContentTypeOpenAccessAudiobook,
      ContentTypeFeedbooksAudiobook,
      ContentTypeOverdriveAudiobook,
      ContentTypeAudiobookZip,
      ContentTypeAudiobookLCP
    ]
  }

  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? TPPOPDSAcquisitionPath else { return false }
    return relation == other.relation && types == other.types
  }

  override var hash: Int {
    let prime = 31
    var result = 1
    result = prime * result + relation.rawValue
    result = prime * result + types.hashValue
    return result
  }

  @objc static func supportedAcquisitionPaths(
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
