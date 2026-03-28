import Foundation

// MARK: - TPPOPDSIndirectAcquisition (Swift port of TPPOPDSIndirectAcquisition.m)

/// Dictionary keys for serialization (must match ObjC keys exactly).
private let indirectAcquisitionTypeKey = "type"
private let indirectAcquisitionIndirectAcquisitionsKey = "indirectAcquisitions"

/// Swift reimplementation of the ObjC TPPOPDSIndirectAcquisition model.
/// Represents a nested/indirect content type obtainable through an acquisition.
@objc(TPPOPDSIndirectAcquisitionSwift)
public final class TPPOPDSIndirectAcquisitionSwift: NSObject {

  /// The type of the content indirectly obtainable.
  @objc public let type: String

  /// Zero or more nested indirect acquisitions.
  @objc public let indirectAcquisitions: [TPPOPDSIndirectAcquisitionSwift]

  /// Designated initializer.
  @objc public init(type: String, indirectAcquisitions: [TPPOPDSIndirectAcquisitionSwift]) {
    self.type = type
    self.indirectAcquisitions = indirectAcquisitions
    super.init()
  }

  /// Factory method matching the ObjC `+indirectAcquisitionWithType:indirectAcquisitions:`.
  @objc public static func indirectAcquisition(
    withType type: String,
    indirectAcquisitions: [TPPOPDSIndirectAcquisitionSwift]
  ) -> TPPOPDSIndirectAcquisitionSwift {
    return TPPOPDSIndirectAcquisitionSwift(type: type, indirectAcquisitions: indirectAcquisitions)
  }

  /// Factory method that parses from XML.
  /// Returns `nil` if the XML element lacks a `type` attribute.
  @objc public static func indirectAcquisition(withXML xml: TPPXML) -> TPPOPDSIndirectAcquisitionSwift? {
    guard let type = xml.attributes["type"] as? String else {
      return nil
    }

    var nestedAcquisitions: [TPPOPDSIndirectAcquisitionSwift] = []
    for child in xml.children(withName: "indirectAcquisition") {
      guard let childXML = child as? TPPXML else { continue }
      if let nested = TPPOPDSIndirectAcquisitionSwift.indirectAcquisition(withXML: childXML) {
        nestedAcquisitions.append(nested)
      } else {
        Log.warn(#file, "Ignoring invalid indirect acquisition.")
      }
    }

    return TPPOPDSIndirectAcquisitionSwift(type: type, indirectAcquisitions: nestedAcquisitions)
  }

  /// Factory method that deserializes from a dictionary.
  /// Returns `nil` if the dictionary is not valid.
  @objc public static func indirectAcquisition(withDictionary dictionary: NSDictionary) -> TPPOPDSIndirectAcquisitionSwift? {
    guard let type = dictionary[indirectAcquisitionTypeKey] as? String else {
      return nil
    }

    guard let indirectDicts = dictionary[indirectAcquisitionIndirectAcquisitionsKey] as? [NSDictionary] else {
      return nil
    }

    var nestedAcquisitions: [TPPOPDSIndirectAcquisitionSwift] = []
    for dict in indirectDicts {
      guard let nested = TPPOPDSIndirectAcquisitionSwift.indirectAcquisition(withDictionary: dict) else {
        return nil
      }
      nestedAcquisitions.append(nested)
    }

    return TPPOPDSIndirectAcquisitionSwift(type: type, indirectAcquisitions: nestedAcquisitions)
  }

  /// Serializes to a dictionary representation.
  @objc public func dictionaryRepresentation() -> NSDictionary {
    let nestedDicts = indirectAcquisitions.map { $0.dictionaryRepresentation() }
    return [
      indirectAcquisitionTypeKey: type,
      indirectAcquisitionIndirectAcquisitionsKey: nestedDicts
    ] as NSDictionary
  }
}
