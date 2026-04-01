import Foundation

@objc class TPPOPDSIndirectAcquisition: NSObject {

  @objc private(set) var type: String
  @objc private(set) var indirectAcquisitions: [TPPOPDSIndirectAcquisition]

  private static let typeKey = "type"
  private static let indirectAcquisitionsKey = "indirectAcquisitions"

  @objc init(type: String, indirectAcquisitions: [TPPOPDSIndirectAcquisition]) {
    self.type = type
    self.indirectAcquisitions = indirectAcquisitions
    super.init()
  }

  @objc static func indirectAcquisition(withType type: String, indirectAcquisitions: [TPPOPDSIndirectAcquisition]) -> TPPOPDSIndirectAcquisition {
    return TPPOPDSIndirectAcquisition(type: type, indirectAcquisitions: indirectAcquisitions)
  }

  @objc static func indirectAcquisition(withXML xml: TPPXML) -> TPPOPDSIndirectAcquisition? {
    guard let type = (xml.attributes as? [String: String])?["type"] else {
      return nil
    }

    var mutableIndirectAcquisitions = [TPPOPDSIndirectAcquisition]()
    for childXML in xml.childrenWithName("indirectAcquisition") {
      if let indirect = TPPOPDSIndirectAcquisition.indirectAcquisition(withXML: childXML) {
        mutableIndirectAcquisitions.append(indirect)
      } else {
        Log.log("Ignoring invalid indirect acquisition.")
      }
    }

    return indirectAcquisition(withType: type, indirectAcquisitions: mutableIndirectAcquisitions)
  }

  @objc static func indirectAcquisition(withDictionary dictionary: NSDictionary) -> TPPOPDSIndirectAcquisition? {
    guard let type = dictionary[typeKey] as? String else {
      return nil
    }

    guard let indirectAcquisitionDicts = dictionary[indirectAcquisitionsKey] as? [NSDictionary] else {
      return nil
    }

    var mutableIndirectAcquisitions = [TPPOPDSIndirectAcquisition]()
    for dict in indirectAcquisitionDicts {
      guard let indirect = TPPOPDSIndirectAcquisition.indirectAcquisition(withDictionary: dict) else {
        return nil
      }
      mutableIndirectAcquisitions.append(indirect)
    }

    return indirectAcquisition(withType: type, indirectAcquisitions: mutableIndirectAcquisitions)
  }

  @objc func dictionaryRepresentation() -> NSDictionary {
    let indirectDicts = indirectAcquisitions.map { $0.dictionaryRepresentation() }
    return [
      TPPOPDSIndirectAcquisition.typeKey: type,
      TPPOPDSIndirectAcquisition.indirectAcquisitionsKey: indirectDicts
    ] as NSDictionary
  }
}
