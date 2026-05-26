import Foundation
import PalaceLogging

@objc public enum TPPOPDSAcquisitionRelation: Int {
  case generic
  case openAccess
  case borrow
  case buy
  case sample
  case preview
  case subscribe
}

public struct TPPOPDSAcquisitionRelationSet: OptionSet {
  public let rawValue: UInt

  public init(rawValue: UInt) {
    self.rawValue = rawValue
  }

  public static let generic    = TPPOPDSAcquisitionRelationSet(rawValue: 1 << 0)
  public static let openAccess = TPPOPDSAcquisitionRelationSet(rawValue: 1 << 1)
  public static let borrow     = TPPOPDSAcquisitionRelationSet(rawValue: 1 << 2)
  public static let buy        = TPPOPDSAcquisitionRelationSet(rawValue: 1 << 3)
  public static let sample     = TPPOPDSAcquisitionRelationSet(rawValue: 1 << 4)
  public static let preview    = TPPOPDSAcquisitionRelationSet(rawValue: 1 << 5)
  public static let subscribe  = TPPOPDSAcquisitionRelationSet(rawValue: 1 << 6)

  static public let all: TPPOPDSAcquisitionRelationSet = [.generic, .openAccess, .borrow, .buy, .sample, .preview, .subscribe]
  static public let defaultAcquisition: TPPOPDSAcquisitionRelationSet = all.subtracting(.sample)
}

public let NYPLOPDSAcquisitionRelationSetAll: UInt = TPPOPDSAcquisitionRelationSet.all.rawValue
public let TPPOPDSAcquisitionRelationSetDefaultAcquisition: UInt = TPPOPDSAcquisitionRelationSet.defaultAcquisition.rawValue

// Backward-compatible set constants
public let TPPOPDSAcquisitionRelationSetGeneric: UInt = TPPOPDSAcquisitionRelationSet.generic.rawValue
public let TPPOPDSAcquisitionRelationSetOpenAccess: UInt = TPPOPDSAcquisitionRelationSet.openAccess.rawValue
public let TPPOPDSAcquisitionRelationSetBorrow: UInt = TPPOPDSAcquisitionRelationSet.borrow.rawValue
public let TPPOPDSAcquisitionRelationSetBuy: UInt = TPPOPDSAcquisitionRelationSet.buy.rawValue
public let TPPOPDSAcquisitionRelationSetSample: UInt = TPPOPDSAcquisitionRelationSet.sample.rawValue
public let TPPOPDSAcquisitionRelationSetPreview: UInt = TPPOPDSAcquisitionRelationSet.preview.rawValue
public let TPPOPDSAcquisitionRelationSetSubscribe: UInt = TPPOPDSAcquisitionRelationSet.subscribe.rawValue

public func NYPLOPDSAcquisitionRelationSetWithRelation(_ relation: TPPOPDSAcquisitionRelation) -> UInt {
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

public func NYPLOPDSAcquisitionRelationSetContainsRelation(_ relationSet: UInt, _ relation: TPPOPDSAcquisitionRelation) -> Bool {
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

public func NYPLOPDSAcquisitionRelationWithString(_ string: String, _ relationPointer: UnsafeMutablePointer<TPPOPDSAcquisitionRelation>) -> Bool {
  guard let relation = relationStringMap[string] else { return false }
  relationPointer.pointee = relation
  return true
}

public func NYPLOPDSAcquisitionRelationString(_ relation: TPPOPDSAcquisitionRelation) -> String {
  return relationToString[relation] ?? ""
}

// MARK: - TPPOPDSAcquisition

@objc public class TPPOPDSAcquisition: NSObject {

  @objc public private(set) var relation: TPPOPDSAcquisitionRelation
  @objc public private(set) var type: String
  @objc public private(set) var hrefURL: URL
  @objc public private(set) var indirectAcquisitions: [TPPOPDSIndirectAcquisition]
  @objc public private(set) var availability: TPPOPDSAcquisitionAvailability

  private static let availabilityKey = "availability"
  private static let hrefURLKey = "href"
  // NOTE: The misspelling "indirectAcqusitions" (missing 'i') is preserved for
  // backward compatibility with data persisted by older ObjC versions of this code.
  private static let indirectAcquisitionsKey = "indirectAcqusitions"
  private static let relationKey = "rel"
  private static let typeKey = "type"

  @objc public init(relation: TPPOPDSAcquisitionRelation, type: String, hrefURL: URL, indirectAcquisitions: [TPPOPDSIndirectAcquisition], availability: TPPOPDSAcquisitionAvailability) {
    self.relation = relation
    self.type = type
    self.hrefURL = hrefURL
    self.indirectAcquisitions = indirectAcquisitions
    self.availability = availability
    super.init()
  }

  @objc public static func acquisition(withRelation relation: TPPOPDSAcquisitionRelation, type: String, hrefURL: URL, indirectAcquisitions: [TPPOPDSIndirectAcquisition], availability: TPPOPDSAcquisitionAvailability) -> TPPOPDSAcquisition {
    return TPPOPDSAcquisition(relation: relation, type: type, hrefURL: hrefURL, indirectAcquisitions: indirectAcquisitions, availability: availability)
  }

  @objc public static func acquisition(withLinkXML linkXML: TPPXML) -> TPPOPDSAcquisition? {
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

  @objc public static func acquisition(withDictionary dictionary: NSDictionary) -> TPPOPDSAcquisition? {
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

  @objc public func dictionaryRepresentation() -> NSDictionary {
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
