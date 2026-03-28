import Foundation

// MARK: - TPPOPDSIndirectAcquisition (Swift port of TPPOPDSIndirectAcquisition.m)

/// Dictionary keys for serialization (must match ObjC keys exactly).
private let indirectAcquisitionTypeKey = "type"
private let indirectAcquisitionIndirectAcquisitionsKey = "indirectAcquisitions"

/// Swift reimplementation of the ObjC TPPOPDSIndirectAcquisition model.
/// Represents a nested/indirect content type obtainable through an acquisition.
@objc(TPPOPDSIndirectAcquisition)
public final class TPPOPDSIndirectAcquisition: NSObject {

  /// The type of the content indirectly obtainable.
  @objc public let type: String

  /// Zero or more nested indirect acquisitions.
  @objc public let indirectAcquisitions: [TPPOPDSIndirectAcquisition]

  /// Designated initializer.
  @objc public init(type: String, indirectAcquisitions: [TPPOPDSIndirectAcquisition]) {
    self.type = type
    self.indirectAcquisitions = indirectAcquisitions
    super.init()
  }

  /// Factory method matching the ObjC `+indirectAcquisitionWithType:indirectAcquisitions:`.
  @objc public static func indirectAcquisition(
    withType type: String,
    indirectAcquisitions: [TPPOPDSIndirectAcquisition]
  ) -> TPPOPDSIndirectAcquisition {
    return TPPOPDSIndirectAcquisition(type: type, indirectAcquisitions: indirectAcquisitions)
  }

  /// Convenience initializer from XML.
  @objc convenience init?(xml: TPPXML) {
    guard let type = xml.attributes["type"] as? String else {
      return nil
    }
    var nested: [TPPOPDSIndirectAcquisition] = []
    for child in xml.children(withName: "indirectAcquisition") {
      guard let childXML = child as? TPPXML else { continue }
      if let n = TPPOPDSIndirectAcquisition(xml: childXML) {
        nested.append(n)
      }
    }
    self.init(type: type, indirectAcquisitions: nested)
  }

  /// Convenience initializer from dictionary.
  @objc public convenience init?(dictionary: NSDictionary) {
    guard let type = dictionary[indirectAcquisitionTypeKey] as? String else { return nil }
    guard let dicts = dictionary[indirectAcquisitionIndirectAcquisitionsKey] as? [NSDictionary] else { return nil }
    var nested: [TPPOPDSIndirectAcquisition] = []
    for d in dicts {
      guard let n = TPPOPDSIndirectAcquisition(dictionary: d) else { return nil }
      nested.append(n)
    }
    self.init(type: type, indirectAcquisitions: nested)
  }

  /// Factory method that parses from XML.
  /// Returns `nil` if the XML element lacks a `type` attribute.
  @objc static func indirectAcquisition(withXML xml: TPPXML) -> TPPOPDSIndirectAcquisition? {
    guard let type = xml.attributes["type"] as? String else {
      return nil
    }

    var nestedAcquisitions: [TPPOPDSIndirectAcquisition] = []
    for child in xml.children(withName: "indirectAcquisition") {
      guard let childXML = child as? TPPXML else { continue }
      if let nested = TPPOPDSIndirectAcquisition.indirectAcquisition(withXML: childXML) {
        nestedAcquisitions.append(nested)
      } else {
        Log.warn(#file, "Ignoring invalid indirect acquisition.")
      }
    }

    return TPPOPDSIndirectAcquisition(type: type, indirectAcquisitions: nestedAcquisitions)
  }

  /// Factory method that deserializes from a dictionary.
  /// Returns `nil` if the dictionary is not valid.
  @objc public static func indirectAcquisition(withDictionary dictionary: NSDictionary) -> TPPOPDSIndirectAcquisition? {
    guard let type = dictionary[indirectAcquisitionTypeKey] as? String else {
      return nil
    }

    guard let indirectDicts = dictionary[indirectAcquisitionIndirectAcquisitionsKey] as? [NSDictionary] else {
      return nil
    }

    var nestedAcquisitions: [TPPOPDSIndirectAcquisition] = []
    for dict in indirectDicts {
      guard let nested = TPPOPDSIndirectAcquisition.indirectAcquisition(withDictionary: dict) else {
        return nil
      }
      nestedAcquisitions.append(nested)
    }

    return TPPOPDSIndirectAcquisition(type: type, indirectAcquisitions: nestedAcquisitions)
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
