import Foundation

@objc enum TPPOPDSAcquisitionRelation: Int {
  case generic
  case openAccess
  case borrow
  case buy
  case sample
  case preview
  case subscribe
}

struct TPPOPDSAcquisitionRelationSet: OptionSet {
  let rawValue: UInt

  static let generic    = TPPOPDSAcquisitionRelationSet(rawValue: 1 << 0)
  static let openAccess = TPPOPDSAcquisitionRelationSet(rawValue: 1 << 1)
  static let borrow     = TPPOPDSAcquisitionRelationSet(rawValue: 1 << 2)
  static let buy        = TPPOPDSAcquisitionRelationSet(rawValue: 1 << 3)
  static let sample     = TPPOPDSAcquisitionRelationSet(rawValue: 1 << 4)
  static let preview    = TPPOPDSAcquisitionRelationSet(rawValue: 1 << 5)
  static let subscribe  = TPPOPDSAcquisitionRelationSet(rawValue: 1 << 6)

  static let all: TPPOPDSAcquisitionRelationSet = [.generic, .openAccess, .borrow, .buy, .sample, .preview, .subscribe]
  static let defaultAcquisition: TPPOPDSAcquisitionRelationSet = all.subtracting(.sample)
}

let NYPLOPDSAcquisitionRelationSetAll: UInt = TPPOPDSAcquisitionRelationSet.all.rawValue
let TPPOPDSAcquisitionRelationSetDefaultAcquisition: UInt = TPPOPDSAcquisitionRelationSet.defaultAcquisition.rawValue

// Backward-compatible set constants
let TPPOPDSAcquisitionRelationSetGeneric: UInt = TPPOPDSAcquisitionRelationSet.generic.rawValue
let TPPOPDSAcquisitionRelationSetOpenAccess: UInt = TPPOPDSAcquisitionRelationSet.openAccess.rawValue
let TPPOPDSAcquisitionRelationSetBorrow: UInt = TPPOPDSAcquisitionRelationSet.borrow.rawValue
let TPPOPDSAcquisitionRelationSetBuy: UInt = TPPOPDSAcquisitionRelationSet.buy.rawValue
let TPPOPDSAcquisitionRelationSetSample: UInt = TPPOPDSAcquisitionRelationSet.sample.rawValue
let TPPOPDSAcquisitionRelationSetPreview: UInt = TPPOPDSAcquisitionRelationSet.preview.rawValue
let TPPOPDSAcquisitionRelationSetSubscribe: UInt = TPPOPDSAcquisitionRelationSet.subscribe.rawValue

func NYPLOPDSAcquisitionRelationSetWithRelation(_ relation: TPPOPDSAcquisitionRelation) -> UInt {
  switch relation {
  case .generic:    return TPPOPDSAcquisitionRelationSetGeneric
  case .openAccess: return TPPOPDSAcquisitionRelationSetOpenAccess
  case .borrow:     return TPPOPDSAcquisitionRelationSetBorrow
  case .buy:        return TPPOPDSAcquisitionRelationSetBuy
  case .sample:     return TPPOPDSAcquisitionRelationSetSample
  case .preview:    return TPPOPDSAcquisitionRelationSetPreview
  case .subscribe:  return TPPOPDSAcquisitionRelationSetSubscribe
  }
}

func NYPLOPDSAcquisitionRelationSetContainsRelation(_ relationSet: UInt, _ relation: TPPOPDSAcquisitionRelation) -> Bool {
  return NYPLOPDSAcquisitionRelationSetWithRelation(relation) & relationSet != 0
}

private let relationStringMap: [String: TPPOPDSAcquisitionRelation] = [
  "http://opds-spec.org/acquisition": .generic,
  "http://opds-spec.org/acquisition/open-access": .openAccess,
  "http://opds-spec.org/acquisition/borrow": .borrow,
  "http://opds-spec.org/acquisition/buy": .buy,
  "http://opds-spec.org/acquisition/sample": .sample,
  "preview": .preview,
  "http://opds-spec.org/acquisition/preview": .preview,
  "http://opds-spec.org/acquisition/subscribe": .subscribe
]

private let relationToString: [TPPOPDSAcquisitionRelation: String] = [
  .generic: "http://opds-spec.org/acquisition",
  .openAccess: "http://opds-spec.org/acquisition/open-access",
  .borrow: "http://opds-spec.org/acquisition/borrow",
  .buy: "http://opds-spec.org/acquisition/buy",
  .sample: "http://opds-spec.org/acquisition/sample",
  .preview: "preview",
  .subscribe: "http://opds-spec.org/acquisition/subscribe"
]

func NYPLOPDSAcquisitionRelationWithString(_ string: String, _ relationPointer: UnsafeMutablePointer<TPPOPDSAcquisitionRelation>) -> Bool {
  guard let relation = relationStringMap[string] else { return false }
  relationPointer.pointee = relation
  return true
}

func NYPLOPDSAcquisitionRelationString(_ relation: TPPOPDSAcquisitionRelation) -> String {
  return relationToString[relation] ?? ""
}

// MARK: - TPPOPDSAcquisition

@objc class TPPOPDSAcquisition: NSObject {

  @objc private(set) var relation: TPPOPDSAcquisitionRelation
  @objc private(set) var type: String
  @objc private(set) var hrefURL: URL
  @objc private(set) var indirectAcquisitions: [TPPOPDSIndirectAcquisition]
  @objc private(set) var availability: TPPOPDSAcquisitionAvailability

  private static let availabilityKey = "availability"
  private static let hrefURLKey = "href"
  // NOTE: The misspelling "indirectAcqusitions" (missing 'i') is preserved for
  // backward compatibility with data persisted by older ObjC versions of this code.
  private static let indirectAcquisitionsKey = "indirectAcqusitions"
  private static let relationKey = "rel"
  private static let typeKey = "type"

  @objc init(relation: TPPOPDSAcquisitionRelation, type: String, hrefURL: URL, indirectAcquisitions: [TPPOPDSIndirectAcquisition], availability: TPPOPDSAcquisitionAvailability) {
    self.relation = relation
    self.type = type
    self.hrefURL = hrefURL
    self.indirectAcquisitions = indirectAcquisitions
    self.availability = availability
    super.init()
  }

  @objc static func acquisition(withRelation relation: TPPOPDSAcquisitionRelation, type: String, hrefURL: URL, indirectAcquisitions: [TPPOPDSIndirectAcquisition], availability: TPPOPDSAcquisitionAvailability) -> TPPOPDSAcquisition {
    return TPPOPDSAcquisition(relation: relation, type: type, hrefURL: hrefURL, indirectAcquisitions: indirectAcquisitions, availability: availability)
  }

  @objc static func acquisition(withLinkXML linkXML: TPPXML) -> TPPOPDSAcquisition? {
    let attrs = linkXML.attributes as? [String: String] ?? [:]

    guard let relationString = attrs["rel"] else { return nil }

    var relation: TPPOPDSAcquisitionRelation = .generic
    guard NYPLOPDSAcquisitionRelationWithString(relationString, &relation) else { return nil }

    guard let type = attrs["type"] else { return nil }
    guard let hrefString = attrs["href"], let hrefURL = URL(string: hrefString) else { return nil }

    var indirectAcquisitions = [TPPOPDSIndirectAcquisition]()
    for childXML in linkXML.childrenWithName("indirectAcquisition") {
      if let indirect = TPPOPDSIndirectAcquisition.indirectAcquisition(withXML: childXML) {
        indirectAcquisitions.append(indirect)
      } else {
        Log.log("Ignoring invalid indirect acquisition.")
      }
    }

    return acquisition(
      withRelation: relation,
      type: type,
      hrefURL: hrefURL,
      indirectAcquisitions: indirectAcquisitions,
      availability: NYPLOPDSAcquisitionAvailabilityWithLinkXML(linkXML)
    )
  }

  @objc static func acquisition(withDictionary dictionary: NSDictionary) -> TPPOPDSAcquisition? {
    guard let relationString = dictionary[TPPOPDSAcquisition.relationKey] as? String else { return nil }
    var relation: TPPOPDSAcquisitionRelation = .generic
    guard NYPLOPDSAcquisitionRelationWithString(relationString, &relation) else { return nil }

    guard let type = dictionary[TPPOPDSAcquisition.typeKey] as? String else { return nil }
    guard let hrefURLString = dictionary[TPPOPDSAcquisition.hrefURLKey] as? String,
          let hrefURL = URL(string: hrefURLString) else { return nil }

    guard let indirectDicts = dictionary[TPPOPDSAcquisition.indirectAcquisitionsKey] as? [NSDictionary] else { return nil }

    var indirectAcquisitions = [TPPOPDSIndirectAcquisition]()
    for dict in indirectDicts {
      guard let indirect = TPPOPDSIndirectAcquisition.indirectAcquisition(withDictionary: dict) else { return nil }
      indirectAcquisitions.append(indirect)
    }

    guard let availDict = dictionary[TPPOPDSAcquisition.availabilityKey] as? NSDictionary,
          let availability = NYPLOPDSAcquisitionAvailabilityWithDictionary(availDict) else { return nil }

    return acquisition(
      withRelation: relation,
      type: type,
      hrefURL: hrefURL,
      indirectAcquisitions: indirectAcquisitions,
      availability: availability
    )
  }

  @objc func dictionaryRepresentation() -> NSDictionary {
    let indirectDicts = indirectAcquisitions.map { $0.dictionaryRepresentation() }
    return [
      TPPOPDSAcquisition.relationKey: NYPLOPDSAcquisitionRelationString(relation),
      TPPOPDSAcquisition.typeKey: type,
      TPPOPDSAcquisition.hrefURLKey: hrefURL.absoluteString,
      TPPOPDSAcquisition.indirectAcquisitionsKey: indirectDicts,
      TPPOPDSAcquisition.availabilityKey: NYPLOPDSAcquisitionAvailabilityDictionaryRepresentation(availability)
    ] as NSDictionary
  }
}
