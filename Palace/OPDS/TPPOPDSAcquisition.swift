import Foundation

// MARK: - TPPOPDSAcquisition (Swift port of TPPOPDSAcquisition.m)

// Relation string constants (must match ObjC values exactly)
private let borrowRelation = "http://opds-spec.org/acquisition/borrow"
private let buyRelation = "http://opds-spec.org/acquisition/buy"
private let genericRelation = "http://opds-spec.org/acquisition"
private let openAccessRelation = "http://opds-spec.org/acquisition/open-access"
private let sampleRelation = "http://opds-spec.org/acquisition/sample"
private let subscribeRelation = "http://opds-spec.org/acquisition/subscribe"
private let previewRelation = "preview"
private let acquisitionPreviewRelation = "http://opds-spec.org/acquisition/preview"

// Dictionary keys for serialization (must match ObjC keys exactly)
private let acqAvailabilityKey = "availability"
private let acqHrefURLKey = "href"
private let acqIndirectAcquisitionsKey = "indirectAcqusitions"  // Note: ObjC typo preserved
private let acqRelationKey = "rel"
private let acqTypeKey = "type"

// XML attribute names
private let acqRelAttribute = "rel"
private let acqTypeAttribute = "type"
private let acqHrefAttribute = "href"
private let acqIndirectAcquisitionName = "indirectAcquisition"

/// Lazy map from relation string to enum value.
private let stringToRelationMap: [String: TPPOPDSAcquisitionRelation] = [
  genericRelation: .generic,
  openAccessRelation: .openAccess,
  borrowRelation: .borrow,
  buyRelation: .buy,
  sampleRelation: .sample,
  previewRelation: .preview,
  acquisitionPreviewRelation: .preview,
  subscribeRelation: .subscribe
]

// MARK: - Constants

/// A set containing all possible relations.
public let NYPLOPDSAcquisitionRelationSetAll: TPPOPDSAcquisitionRelationSet =
  TPPOPDSAcquisitionRelationSet(rawValue: (1 << 7) - 1)

/// A set for `defaultAcquisition` — all relations except sample.
public let TPPOPDSAcquisitionRelationSetDefaultAcquisition: TPPOPDSAcquisitionRelationSet =
  TPPOPDSAcquisitionRelationSet(rawValue: NYPLOPDSAcquisitionRelationSetAll.rawValue & ~TPPOPDSAcquisitionRelationSet.sample.rawValue)

// MARK: - Free Functions

/// Converts a relation enum value to a relation set (single-element).
public func NYPLOPDSAcquisitionRelationSetWithRelation(
  _ relation: TPPOPDSAcquisitionRelation
) -> TPPOPDSAcquisitionRelationSet {
  switch relation {
  case .buy:       return .buy
  case .borrow:    return .borrow
  case .sample:    return .sample
  case .preview:   return .preview
  case .generic:   return .generic
  case .subscribe: return .subscribe
  case .openAccess: return .openAccess
  @unknown default: return TPPOPDSAcquisitionRelationSet(rawValue: 0)
  }
}

/// Returns `true` if `relation` is contained in `relationSet`.
public func NYPLOPDSAcquisitionRelationSetContainsRelation(
  _ relationSet: TPPOPDSAcquisitionRelationSet,
  _ relation: TPPOPDSAcquisitionRelation
) -> Bool {
  return relationSet.contains(NYPLOPDSAcquisitionRelationSetWithRelation(relation))
}

/// Parses a relation string into a `TPPOPDSAcquisitionRelation`.
/// Returns `nil` if the string does not match a known relation.
public func NYPLOPDSAcquisitionRelationFromString(_ string: String) -> TPPOPDSAcquisitionRelation? {
  return stringToRelationMap[string]
}

/// Converts a `TPPOPDSAcquisitionRelation` to its canonical string representation.
public func NYPLOPDSAcquisitionRelationString(_ relation: TPPOPDSAcquisitionRelation) -> String {
  switch relation {
  case .generic:    return genericRelation
  case .openAccess: return openAccessRelation
  case .borrow:     return borrowRelation
  case .buy:        return buyRelation
  case .sample:     return sampleRelation
  case .preview:    return previewRelation
  case .subscribe:  return subscribeRelation
  @unknown default: return genericRelation
  }
}

// MARK: - TPPOPDSAcquisition Swift Implementation

/// Swift reimplementation of the ObjC TPPOPDSAcquisition model.
@objc(TPPOPDSAcquisition)
public final class TPPOPDSAcquisition: NSObject {

  /// The relation of the acquisition link.
  @objc public let relation: TPPOPDSAcquisitionRelation

  /// The type of content immediately retrievable at `hrefURL`.
  @objc public let type: String

  /// The location at which content of type `type` can be retrieved.
  @objc public let hrefURL: URL

  /// Zero or more indirect acquisition objects.
  @objc public let indirectAcquisitions: [TPPOPDSIndirectAcquisition]

  /// The availability of the result of the acquisition.
  @objc public let availability: TPPOPDSAcquisitionAvailability

  /// Designated initializer.
  @objc public init(
    relation: TPPOPDSAcquisitionRelation,
    type: String,
    hrefURL: URL,
    indirectAcquisitions: [TPPOPDSIndirectAcquisition],
    availability: TPPOPDSAcquisitionAvailability
  ) {
    self.relation = relation
    self.type = type
    self.hrefURL = hrefURL
    self.indirectAcquisitions = indirectAcquisitions
    self.availability = availability
    super.init()
  }

  /// Factory method matching ObjC `+acquisitionWithRelation:type:hrefURL:indirectAcquisitions:availability:`.
  @objc public static func acquisition(
    withRelation relation: TPPOPDSAcquisitionRelation,
    type: String,
    hrefURL: URL,
    indirectAcquisitions: [TPPOPDSIndirectAcquisition],
    availability: TPPOPDSAcquisitionAvailability
  ) -> TPPOPDSAcquisition {
    return TPPOPDSAcquisition(
      relation: relation,
      type: type,
      hrefURL: hrefURL,
      indirectAcquisitions: indirectAcquisitions,
      availability: availability
    )
  }

  /// Convenience initializer from link XML.
  @objc convenience init?(linkXML: TPPXML) {
    guard let result = TPPOPDSAcquisition.acquisition(withLinkXML: linkXML) else {
      return nil
    }
    self.init(relation: result.relation, type: result.type, hrefURL: result.hrefURL,
              indirectAcquisitions: result.indirectAcquisitions, availability: result.availability)
  }

  /// Convenience initializer from dictionary.
  @objc public convenience init?(dictionary: NSDictionary) {
    guard let result = TPPOPDSAcquisition.acquisition(withDictionary: dictionary) else {
      return nil
    }
    self.init(relation: result.relation, type: result.type, hrefURL: result.hrefURL,
              indirectAcquisitions: result.indirectAcquisitions, availability: result.availability)
  }

  /// Factory method that parses from a link XML element.
  /// Returns `nil` if the XML element lacks required attributes.
  @objc static func acquisition(withLinkXML linkXML: TPPXML) -> TPPOPDSAcquisition? {
    guard let relationString = linkXML.attributes[acqRelAttribute] as? String,
          let relation = NYPLOPDSAcquisitionRelationFromString(relationString) else {
      return nil
    }

    guard let type = linkXML.attributes[acqTypeAttribute] as? String else {
      return nil
    }

    guard let hrefString = linkXML.attributes[acqHrefAttribute] as? String,
          let hrefURL = URL(string: hrefString) else {
      return nil
    }

    var mutableIndirect: [TPPOPDSIndirectAcquisition] = []
    for child in linkXML.children(withName: acqIndirectAcquisitionName) {
      guard let childXML = child as? TPPXML else { continue }
      if let indirect = TPPOPDSIndirectAcquisition(xml: childXML) {
        mutableIndirect.append(indirect)
      } else {
        Log.warn(#file, "Ignoring invalid indirect acquisition.")
      }
    }

    return TPPOPDSAcquisition(
      relation: relation,
      type: type,
      hrefURL: hrefURL,
      indirectAcquisitions: mutableIndirect,
      availability: NYPLOPDSAcquisitionAvailabilityWithLinkXML(linkXML)
    )
  }

  /// Factory method that deserializes from a dictionary.
  @objc public static func acquisition(withDictionary dictionary: NSDictionary) -> TPPOPDSAcquisition? {
    guard let relationString = dictionary[acqRelationKey] as? String,
          let relation = NYPLOPDSAcquisitionRelationFromString(relationString) else {
      return nil
    }

    guard let type = dictionary[acqTypeKey] as? String else {
      return nil
    }

    guard let hrefURLString = dictionary[acqHrefURLKey] as? String,
          let hrefURL = URL(string: hrefURLString) else {
      return nil
    }

    guard let indirectDicts = dictionary[acqIndirectAcquisitionsKey] as? [NSDictionary] else {
      return nil
    }

    var mutableIndirect: [TPPOPDSIndirectAcquisition] = []
    for dict in indirectDicts {
      guard let indirect = TPPOPDSIndirectAcquisition(dictionary: dict) else {
        return nil
      }
      mutableIndirect.append(indirect)
    }

    guard let availDict = dictionary[acqAvailabilityKey] as? NSDictionary,
          let availability = NYPLOPDSAcquisitionAvailabilityWithDictionary(availDict) else {
      return nil
    }

    return TPPOPDSAcquisition(
      relation: relation,
      type: type,
      hrefURL: hrefURL,
      indirectAcquisitions: mutableIndirect,
      availability: availability
    )
  }

  /// Serializes to a dictionary representation.
  @objc public func dictionaryRepresentation() -> NSDictionary {
    let indirectDicts = indirectAcquisitions.map { $0.dictionaryRepresentation() }
    return [
      acqRelationKey: NYPLOPDSAcquisitionRelationString(relation),
      acqTypeKey: type,
      acqHrefURLKey: hrefURL.absoluteString,
      acqIndirectAcquisitionsKey: indirectDicts,
      acqAvailabilityKey: NYPLOPDSAcquisitionAvailabilityDictionaryRepresentation(availability)
    ] as NSDictionary
  }
}
