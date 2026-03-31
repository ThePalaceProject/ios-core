import Foundation

typealias TPPOPDSAcquisitionAvailabilityCopies = UInt

let TPPOPDSAcquisitionAvailabilityCopiesUnknown: TPPOPDSAcquisitionAvailabilityCopies = UInt.max

@objc protocol TPPOPDSAcquisitionAvailability: NSObjectProtocol {
  var since: Date? { get }
  var until: Date? { get }

  func match(
    unavailable: ((TPPOPDSAcquisitionAvailabilityUnavailable) -> Void)?,
    limited: ((TPPOPDSAcquisitionAvailabilityLimited) -> Void)?,
    unlimited: ((TPPOPDSAcquisitionAvailabilityUnlimited) -> Void)?,
    reserved: ((TPPOPDSAcquisitionAvailabilityReserved) -> Void)?,
    ready: ((TPPOPDSAcquisitionAvailabilityReady) -> Void)?
  )
}

// MARK: - Free functions

func NYPLOPDSAcquisitionAvailabilityWithLinkXML(_ linkXML: TPPXML) -> TPPOPDSAcquisitionAvailability {
  var copiesHeld = TPPOPDSAcquisitionAvailabilityCopiesUnknown
  var copiesAvailable = TPPOPDSAcquisitionAvailabilityCopiesUnknown
  var copiesTotal = TPPOPDSAcquisitionAvailabilityCopiesUnknown
  var holdPosition: UInt = 0

  let statusString = (linkXML.firstChild(withName: "availability")?.attributes as? [String: String])?["status"]

  if let posStr = (linkXML.firstChild(withName: "holds")?.attributes as? [String: String])?["position"] {
    holdPosition = UInt(max(0, Int(posStr) ?? 0))
  }
  if let totalStr = (linkXML.firstChild(withName: "holds")?.attributes as? [String: String])?["total"] {
    copiesHeld = UInt(max(0, Int(totalStr) ?? 0))
  }
  if let availStr = (linkXML.firstChild(withName: "copies")?.attributes as? [String: String])?["available"] {
    copiesAvailable = UInt(max(0, Int(availStr) ?? 0))
  }
  if let totalStr = (linkXML.firstChild(withName: "copies")?.attributes as? [String: String])?["total"] {
    copiesTotal = UInt(max(0, Int(totalStr) ?? 0))
  }

  let sinceString = (linkXML.firstChild(withName: "availability")?.attributes as? [String: String])?["since"]
  let since = sinceString.flatMap { NSDate.date(withRFC3339String: $0) as Date? }

  let untilString = (linkXML.firstChild(withName: "availability")?.attributes as? [String: String])?["until"]
  let until = untilString.flatMap { NSDate.date(withRFC3339String: $0) as Date? }

  if statusString == "unavailable" {
    return TPPOPDSAcquisitionAvailabilityUnavailable(
      copiesHeld: min(copiesHeld, copiesTotal),
      copiesTotal: max(copiesHeld, copiesTotal)
    )
  }

  if statusString == "available" {
    if copiesAvailable == TPPOPDSAcquisitionAvailabilityCopiesUnknown
        && copiesTotal == TPPOPDSAcquisitionAvailabilityCopiesUnknown {
      return TPPOPDSAcquisitionAvailabilityUnlimited()
    }
    return TPPOPDSAcquisitionAvailabilityLimited(
      copiesAvailable: min(copiesAvailable, copiesTotal),
      copiesTotal: max(copiesAvailable, copiesTotal),
      since: since,
      until: until
    )
  }

  if statusString == "reserved" {
    return TPPOPDSAcquisitionAvailabilityReserved(
      holdPosition: holdPosition,
      copiesTotal: copiesTotal,
      since: since,
      until: until
    )
  }

  if statusString == "ready" {
    return TPPOPDSAcquisitionAvailabilityReady(since: since, until: until)
  }

  return TPPOPDSAcquisitionAvailabilityUnlimited()
}

func NYPLOPDSAcquisitionAvailabilityWithDictionary(_ dictionary: NSDictionary) -> TPPOPDSAcquisitionAvailability? {
  guard let caseString = dictionary["case"] as? String else { return nil }

  let sinceString = TPPNullToNil(dictionary["since"]) as? String
  let since = sinceString.flatMap { NSDate.date(withRFC3339String: $0) as Date? }

  let untilString = TPPNullToNil(dictionary["until"]) as? String
  let until = untilString.flatMap { NSDate.date(withRFC3339String: $0) as Date? }

  switch caseString {
  case "unavailable":
    guard let copiesHeldNum = dictionary["copiesHeld"] as? NSNumber,
          let copiesTotalNum = dictionary["copiesTotal"] as? NSNumber else { return nil }
    let ch = copiesHeldNum.intValue
    let ct = copiesTotalNum.intValue
    return TPPOPDSAcquisitionAvailabilityUnavailable(
      copiesHeld: UInt(max(0, min(ch, ct))),
      copiesTotal: UInt(max(0, max(ch, ct)))
    )

  case "limited":
    guard let copiesAvailNum = dictionary["copiesAvailable"] as? NSNumber,
          let copiesTotalNum = dictionary["copiesTotal"] as? NSNumber else { return nil }
    let ca = copiesAvailNum.intValue
    let ct = copiesTotalNum.intValue
    return TPPOPDSAcquisitionAvailabilityLimited(
      copiesAvailable: UInt(max(0, min(ca, ct))),
      copiesTotal: UInt(max(0, max(ca, ct))),
      since: since,
      until: until
    )

  case "unlimited":
    return TPPOPDSAcquisitionAvailabilityUnlimited()

  case "reserved":
    guard let holdPosNum = dictionary["holdsPosition"] as? NSNumber,
          let copiesTotalNum = dictionary["copiesTotal"] as? NSNumber else { return nil }
    return TPPOPDSAcquisitionAvailabilityReserved(
      holdPosition: UInt(max(0, holdPosNum.intValue)),
      copiesTotal: UInt(max(0, copiesTotalNum.intValue)),
      since: since,
      until: until
    )

  case "ready":
    return TPPOPDSAcquisitionAvailabilityReady(since: since, until: until)

  default:
    return nil
  }
}

func NYPLOPDSAcquisitionAvailabilityDictionaryRepresentation(_ availability: TPPOPDSAcquisitionAvailability) -> NSDictionary {
  var result: NSDictionary = [:]

  availability.match(
    unavailable: { unavailable in
      result = [
        "case": "unavailable",
        "copiesHeld": NSNumber(value: unavailable.copiesHeld),
        "copiesTotal": NSNumber(value: unavailable.copiesTotal)
      ]
    },
    limited: { limited in
      result = [
        "case": "limited",
        "copiesAvailable": NSNumber(value: limited.copiesAvailable),
        "copiesTotal": NSNumber(value: limited.copiesTotal),
        "since": TPPNullFromNil((limited.since as NSDate?)?.rfc3339String()),
        "until": TPPNullFromNil((limited.until as NSDate?)?.rfc3339String())
      ]
    },
    unlimited: { _ in
      result = ["case": "unlimited"]
    },
    reserved: { reserved in
      result = [
        "case": "reserved",
        "holdsPosition": NSNumber(value: reserved.holdPosition),
        "copiesTotal": NSNumber(value: reserved.copiesTotal),
        "since": TPPNullFromNil((reserved.since as NSDate?)?.rfc3339String()),
        "until": TPPNullFromNil((reserved.until as NSDate?)?.rfc3339String())
      ]
    },
    ready: { _ in
      result = ["case": "ready"]
    }
  )

  return result
}

// MARK: - Concrete availability classes

@objc class TPPOPDSAcquisitionAvailabilityUnavailable: NSObject, TPPOPDSAcquisitionAvailability {
  @objc let copiesHeld: TPPOPDSAcquisitionAvailabilityCopies
  @objc let copiesTotal: TPPOPDSAcquisitionAvailabilityCopies
  @objc let since: Date? = nil
  @objc let until: Date? = nil

  @objc init(copiesHeld: TPPOPDSAcquisitionAvailabilityCopies, copiesTotal: TPPOPDSAcquisitionAvailabilityCopies) {
    self.copiesHeld = copiesHeld
    self.copiesTotal = copiesTotal
    super.init()
  }

  @objc func match(
    unavailable: ((TPPOPDSAcquisitionAvailabilityUnavailable) -> Void)?,
    limited: ((TPPOPDSAcquisitionAvailabilityLimited) -> Void)?,
    unlimited: ((TPPOPDSAcquisitionAvailabilityUnlimited) -> Void)?,
    reserved: ((TPPOPDSAcquisitionAvailabilityReserved) -> Void)?,
    ready: ((TPPOPDSAcquisitionAvailabilityReady) -> Void)?
  ) {
    unavailable?(self)
  }
}

@objc class TPPOPDSAcquisitionAvailabilityLimited: NSObject, TPPOPDSAcquisitionAvailability {
  @objc let copiesAvailable: TPPOPDSAcquisitionAvailabilityCopies
  @objc let copiesTotal: TPPOPDSAcquisitionAvailabilityCopies
  @objc let since: Date?
  @objc let until: Date?

  @objc init(copiesAvailable: TPPOPDSAcquisitionAvailabilityCopies, copiesTotal: TPPOPDSAcquisitionAvailabilityCopies, since: Date?, until: Date?) {
    self.copiesAvailable = copiesAvailable
    self.copiesTotal = copiesTotal
    self.since = since
    self.until = until
    super.init()
  }

  @objc func match(
    unavailable: ((TPPOPDSAcquisitionAvailabilityUnavailable) -> Void)?,
    limited: ((TPPOPDSAcquisitionAvailabilityLimited) -> Void)?,
    unlimited: ((TPPOPDSAcquisitionAvailabilityUnlimited) -> Void)?,
    reserved: ((TPPOPDSAcquisitionAvailabilityReserved) -> Void)?,
    ready: ((TPPOPDSAcquisitionAvailabilityReady) -> Void)?
  ) {
    limited?(self)
  }
}

@objc class TPPOPDSAcquisitionAvailabilityUnlimited: NSObject, TPPOPDSAcquisitionAvailability {
  @objc let since: Date? = nil
  @objc let until: Date? = nil

  @objc func match(
    unavailable: ((TPPOPDSAcquisitionAvailabilityUnavailable) -> Void)?,
    limited: ((TPPOPDSAcquisitionAvailabilityLimited) -> Void)?,
    unlimited: ((TPPOPDSAcquisitionAvailabilityUnlimited) -> Void)?,
    reserved: ((TPPOPDSAcquisitionAvailabilityReserved) -> Void)?,
    ready: ((TPPOPDSAcquisitionAvailabilityReady) -> Void)?
  ) {
    unlimited?(self)
  }
}

@objc class TPPOPDSAcquisitionAvailabilityReserved: NSObject, TPPOPDSAcquisitionAvailability {
  @objc let holdPosition: UInt
  @objc let copiesTotal: TPPOPDSAcquisitionAvailabilityCopies
  @objc let since: Date?
  @objc let until: Date?

  @objc init(holdPosition: UInt, copiesTotal: TPPOPDSAcquisitionAvailabilityCopies, since: Date?, until: Date?) {
    self.holdPosition = holdPosition
    self.copiesTotal = copiesTotal
    self.since = since
    self.until = until
    super.init()
  }

  @objc func match(
    unavailable: ((TPPOPDSAcquisitionAvailabilityUnavailable) -> Void)?,
    limited: ((TPPOPDSAcquisitionAvailabilityLimited) -> Void)?,
    unlimited: ((TPPOPDSAcquisitionAvailabilityUnlimited) -> Void)?,
    reserved: ((TPPOPDSAcquisitionAvailabilityReserved) -> Void)?,
    ready: ((TPPOPDSAcquisitionAvailabilityReady) -> Void)?
  ) {
    reserved?(self)
  }
}

@objc class TPPOPDSAcquisitionAvailabilityReady: NSObject, TPPOPDSAcquisitionAvailability {
  @objc let since: Date?
  @objc let until: Date?

  @objc init(since: Date?, until: Date?) {
    self.since = since
    self.until = until
    super.init()
  }

  @objc func match(
    unavailable: ((TPPOPDSAcquisitionAvailabilityUnavailable) -> Void)?,
    limited: ((TPPOPDSAcquisitionAvailabilityLimited) -> Void)?,
    unlimited: ((TPPOPDSAcquisitionAvailabilityUnlimited) -> Void)?,
    reserved: ((TPPOPDSAcquisitionAvailabilityReserved) -> Void)?,
    ready: ((TPPOPDSAcquisitionAvailabilityReady) -> Void)?
  ) {
    ready?(self)
  }
}
