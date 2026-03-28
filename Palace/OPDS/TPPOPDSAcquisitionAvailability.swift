import Foundation

// MARK: - TPPOPDSAcquisitionAvailability (Swift port of TPPOPDSAcquisitionAvailability.m)

/// The sentinel value indicating an unknown number of copies.
/// Matches the ObjC constant `TPPOPDSAcquisitionAvailabilityCopiesUnknown`.
public let TPPOPDSAcquisitionAvailabilityCopiesUnknownSwift: UInt = UInt.max

// MARK: - Dictionary Keys (must match ObjC keys exactly)
private let avCaseKey = "case"
private let avCopiesAvailableKey = "copiesAvailable"
private let avCopiesHeldKey = "copiesHeld"
private let avCopiesTotalKey = "copiesTotal"
private let avHoldsPositionKey = "holdsPosition"
private let avSinceKey = "since"
private let avUntilKey = "until"

private let avLimitedCase = "limited"
private let avReadyCase = "ready"
private let avReservedCase = "reserved"
private let avUnavailableCase = "unavailable"
private let avUnlimitedCase = "unlimited"

// MARK: - XML element/attribute names
private let avAvailabilityName = "availability"
private let avCopiesName = "copies"
private let avHoldsName = "holds"

private let avAvailableAttribute = "available"
private let avPositionAttribute = "position"
private let avSinceAttribute = "since"
private let avStatusAttribute = "status"
private let avTotalAttribute = "total"
private let avUntilAttribute = "until"

// MARK: - Helper: nil <-> NSNull conversion (replaces TPPNullFromNil/TPPNullToNil)

/// Converts nil to NSNull for NSDictionary storage.
private func nullFromNil(_ object: Any?) -> Any {
  return object ?? NSNull()
}

/// Converts NSNull back to nil.
private func nullToNil(_ object: Any?) -> Any? {
  if object is NSNull { return nil }
  return object
}

// MARK: - Protocol

/// The ObjC protocol `TPPOPDSAcquisitionAvailability` is already defined in
/// TPPOPDSAcquisitionAvailability.h and imported via bridging header.
/// This Swift file provides the 5 concrete Swift class implementations
/// and free-function ports.

// MARK: - Unavailable

@objc(TPPOPDSAcquisitionAvailabilityUnavailableSwift)
public final class TPPOPDSAcquisitionAvailabilityUnavailableSwift: NSObject, TPPOPDSAcquisitionAvailability {

  @objc public let copiesHeld: UInt
  @objc public let copiesTotal: UInt

  @objc public var since: Date? { return nil }
  @objc public var until: Date? { return nil }

  @objc public init(copiesHeld: UInt, copiesTotal: UInt) {
    self.copiesHeld = copiesHeld
    self.copiesTotal = copiesTotal
    super.init()
  }

  @objc public func matchUnavailable(
    _ unavailable: ((TPPOPDSAcquisitionAvailabilityUnavailable) -> Void)?,
    limited: ((TPPOPDSAcquisitionAvailabilityLimited) -> Void)?,
    unlimited: ((TPPOPDSAcquisitionAvailabilityUnlimited) -> Void)?,
    reserved: ((TPPOPDSAcquisitionAvailabilityReserved) -> Void)?,
    ready: ((TPPOPDSAcquisitionAvailabilityReady) -> Void)?
  ) {
    // When fully replacing ObjC, this would call unavailable?(self).
    // Currently a placeholder since ObjC classes are still compiled.
  }
}

// MARK: - Limited

@objc(TPPOPDSAcquisitionAvailabilityLimitedSwift)
public final class TPPOPDSAcquisitionAvailabilityLimitedSwift: NSObject, TPPOPDSAcquisitionAvailability {

  @objc public let copiesAvailable: UInt
  @objc public let copiesTotal: UInt
  @objc public let since: Date?
  @objc public let until: Date?

  @objc public init(copiesAvailable: UInt, copiesTotal: UInt, since: Date?, until: Date?) {
    self.copiesAvailable = copiesAvailable
    self.copiesTotal = copiesTotal
    self.since = since
    self.until = until
    super.init()
  }

  @objc public func matchUnavailable(
    _ unavailable: ((TPPOPDSAcquisitionAvailabilityUnavailable) -> Void)?,
    limited: ((TPPOPDSAcquisitionAvailabilityLimited) -> Void)?,
    unlimited: ((TPPOPDSAcquisitionAvailabilityUnlimited) -> Void)?,
    reserved: ((TPPOPDSAcquisitionAvailabilityReserved) -> Void)?,
    ready: ((TPPOPDSAcquisitionAvailabilityReady) -> Void)?
  ) {
    // Placeholder for when this replaces the ObjC version.
  }
}

// MARK: - Unlimited

@objc(TPPOPDSAcquisitionAvailabilityUnlimitedSwift)
public final class TPPOPDSAcquisitionAvailabilityUnlimitedSwift: NSObject, TPPOPDSAcquisitionAvailability {

  @objc public var since: Date? { return nil }
  @objc public var until: Date? { return nil }

  @objc public override init() {
    super.init()
  }

  @objc public func matchUnavailable(
    _ unavailable: ((TPPOPDSAcquisitionAvailabilityUnavailable) -> Void)?,
    limited: ((TPPOPDSAcquisitionAvailabilityLimited) -> Void)?,
    unlimited: ((TPPOPDSAcquisitionAvailabilityUnlimited) -> Void)?,
    reserved: ((TPPOPDSAcquisitionAvailabilityReserved) -> Void)?,
    ready: ((TPPOPDSAcquisitionAvailabilityReady) -> Void)?
  ) {
    // Placeholder for when this replaces the ObjC version.
  }
}

// MARK: - Reserved

@objc(TPPOPDSAcquisitionAvailabilityReservedSwift)
public final class TPPOPDSAcquisitionAvailabilityReservedSwift: NSObject, TPPOPDSAcquisitionAvailability {

  /// If equal to 1, the user is next in line. This value is never 0.
  @objc public let holdPosition: UInt
  @objc public let copiesTotal: UInt
  @objc public let since: Date?
  @objc public let until: Date?

  @objc public init(holdPosition: UInt, copiesTotal: UInt, since: Date?, until: Date?) {
    self.holdPosition = holdPosition
    self.copiesTotal = copiesTotal
    self.since = since
    self.until = until
    super.init()
  }

  @objc public func matchUnavailable(
    _ unavailable: ((TPPOPDSAcquisitionAvailabilityUnavailable) -> Void)?,
    limited: ((TPPOPDSAcquisitionAvailabilityLimited) -> Void)?,
    unlimited: ((TPPOPDSAcquisitionAvailabilityUnlimited) -> Void)?,
    reserved: ((TPPOPDSAcquisitionAvailabilityReserved) -> Void)?,
    ready: ((TPPOPDSAcquisitionAvailabilityReady) -> Void)?
  ) {
    // Placeholder for when this replaces the ObjC version.
  }
}

// MARK: - Ready

@objc(TPPOPDSAcquisitionAvailabilityReadySwift)
public final class TPPOPDSAcquisitionAvailabilityReadySwift: NSObject, TPPOPDSAcquisitionAvailability {

  @objc public let since: Date?
  @objc public let until: Date?

  @objc public init(since: Date?, until: Date?) {
    self.since = since
    self.until = until
    super.init()
  }

  @objc public func matchUnavailable(
    _ unavailable: ((TPPOPDSAcquisitionAvailabilityUnavailable) -> Void)?,
    limited: ((TPPOPDSAcquisitionAvailabilityLimited) -> Void)?,
    unlimited: ((TPPOPDSAcquisitionAvailabilityUnlimited) -> Void)?,
    reserved: ((TPPOPDSAcquisitionAvailabilityReserved) -> Void)?,
    ready: ((TPPOPDSAcquisitionAvailabilityReady) -> Void)?
  ) {
    // Placeholder for when this replaces the ObjC version.
  }
}

// MARK: - Free Functions (Swift ports)

/// Parses availability from an OPDS link XML element.
/// Returns `TPPOPDSAcquisitionAvailabilityUnlimited` as the default.
public func NYPLOPDSAcquisitionAvailabilityWithLinkXMLSwift(_ linkXML: TPPXML) -> TPPOPDSAcquisitionAvailability {
  let copiesUnknown = TPPOPDSAcquisitionAvailabilityCopiesUnknown

  var copiesHeld: UInt = copiesUnknown
  var copiesAvailable: UInt = copiesUnknown
  var copiesTotal: UInt = copiesUnknown
  var holdPosition: UInt = 0

  let statusString = linkXML.firstChild(withName: avAvailabilityName)?.attributes[avStatusAttribute] as? String

  if let posStr = linkXML.firstChild(withName: avHoldsName)?.attributes[avPositionAttribute] as? String,
     let posVal = Int(posStr) {
    holdPosition = UInt(max(0, posVal))
  }

  if let heldStr = linkXML.firstChild(withName: avHoldsName)?.attributes[avTotalAttribute] as? String,
     let heldVal = Int(heldStr) {
    copiesHeld = UInt(max(0, heldVal))
  }

  if let availStr = linkXML.firstChild(withName: avCopiesName)?.attributes[avAvailableAttribute] as? String,
     let availVal = Int(availStr) {
    copiesAvailable = UInt(max(0, availVal))
  }

  if let totalStr = linkXML.firstChild(withName: avCopiesName)?.attributes[avTotalAttribute] as? String,
     let totalVal = Int(totalStr) {
    copiesTotal = UInt(max(0, totalVal))
  }

  let sinceString = linkXML.firstChild(withName: avAvailabilityName)?.attributes[avSinceAttribute] as? String
  let since: Date? = sinceString.flatMap { NSDate(rfc3339String: $0) as Date? }

  let untilString = linkXML.firstChild(withName: avAvailabilityName)?.attributes[avUntilAttribute] as? String
  let until: Date? = untilString.flatMap { NSDate(rfc3339String: $0) as Date? }

  if statusString == "unavailable" {
    return TPPOPDSAcquisitionAvailabilityUnavailable(
      copiesHeld: min(copiesHeld, copiesTotal),
      copiesTotal: max(copiesHeld, copiesTotal)
    )
  }

  if statusString == "available" {
    if copiesAvailable == copiesUnknown && copiesTotal == copiesUnknown {
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

/// Deserializes availability from a dictionary.
/// Returns `nil` if the dictionary is invalid.
public func NYPLOPDSAcquisitionAvailabilityWithDictionarySwift(_ dictionary: NSDictionary) -> TPPOPDSAcquisitionAvailability? {
  guard let caseString = dictionary[avCaseKey] as? String else {
    return nil
  }

  let sinceString = nullToNil(dictionary[avSinceKey]) as? String
  let since: Date? = sinceString.flatMap { NSDate(rfc3339String: $0) as Date? }

  let untilString = nullToNil(dictionary[avUntilKey]) as? String
  let until: Date? = untilString.flatMap { NSDate(rfc3339String: $0) as Date? }

  switch caseString {
  case avUnavailableCase:
    guard let copiesHeldNum = dictionary[avCopiesHeldKey] as? NSNumber,
          let copiesTotalNum = dictionary[avCopiesTotalKey] as? NSNumber else {
      return nil
    }
    let held = copiesHeldNum.intValue
    let total = copiesTotalNum.intValue
    return TPPOPDSAcquisitionAvailabilityUnavailable(
      copiesHeld: UInt(max(0, min(held, total))),
      copiesTotal: UInt(max(0, max(held, total)))
    )

  case avLimitedCase:
    guard let copiesAvailNum = dictionary[avCopiesAvailableKey] as? NSNumber,
          let copiesTotalNum = dictionary[avCopiesTotalKey] as? NSNumber else {
      return nil
    }
    let avail = copiesAvailNum.intValue
    let total = copiesTotalNum.intValue
    return TPPOPDSAcquisitionAvailabilityLimited(
      copiesAvailable: UInt(max(0, min(avail, total))),
      copiesTotal: UInt(max(0, max(avail, total))),
      since: since,
      until: until
    )

  case avUnlimitedCase:
    return TPPOPDSAcquisitionAvailabilityUnlimited()

  case avReservedCase:
    guard let holdPosNum = dictionary[avHoldsPositionKey] as? NSNumber,
          let copiesTotalNum = dictionary[avCopiesTotalKey] as? NSNumber else {
      return nil
    }
    return TPPOPDSAcquisitionAvailabilityReserved(
      holdPosition: UInt(max(0, holdPosNum.intValue)),
      copiesTotal: UInt(max(0, copiesTotalNum.intValue)),
      since: since,
      until: until
    )

  case avReadyCase:
    return TPPOPDSAcquisitionAvailabilityReady(since: since, until: until)

  default:
    return nil
  }
}

/// Serializes availability to a dictionary representation.
public func NYPLOPDSAcquisitionAvailabilityDictionaryRepresentationSwift(
  _ availability: TPPOPDSAcquisitionAvailability
) -> NSDictionary {
  var result: NSDictionary = [:]

  availability.matchUnavailable({ unavailable in
    result = [
      avCaseKey: avUnavailableCase,
      avCopiesHeldKey: NSNumber(value: unavailable.copiesHeld),
      avCopiesTotalKey: NSNumber(value: unavailable.copiesTotal)
    ] as NSDictionary
  }, limited: { limited in
    let sinceStr: Any = limited.since.map { (($0 as NSDate).rfc3339String()) as Any } ?? NSNull()
    let untilStr: Any = limited.until.map { (($0 as NSDate).rfc3339String()) as Any } ?? NSNull()
    result = [
      avCaseKey: avLimitedCase,
      avCopiesAvailableKey: NSNumber(value: limited.copiesAvailable),
      avCopiesTotalKey: NSNumber(value: limited.copiesTotal),
      avSinceKey: sinceStr,
      avUntilKey: untilStr
    ] as NSDictionary
  }, unlimited: { _ in
    result = [
      avCaseKey: avUnlimitedCase
    ] as NSDictionary
  }, reserved: { reserved in
    let sinceStr: Any = reserved.since.map { (($0 as NSDate).rfc3339String()) as Any } ?? NSNull()
    let untilStr: Any = reserved.until.map { (($0 as NSDate).rfc3339String()) as Any } ?? NSNull()
    result = [
      avCaseKey: avReservedCase,
      avHoldsPositionKey: NSNumber(value: reserved.holdPosition),
      avCopiesTotalKey: NSNumber(value: reserved.copiesTotal),
      avSinceKey: sinceStr,
      avUntilKey: untilStr
    ] as NSDictionary
  }, ready: { _ in
    result = [
      avCaseKey: avReadyCase
    ] as NSDictionary
  })

  return result
}
