import Foundation

// MARK: - OPDS Type Functions (Swift port of TPPOPDSType.m)

/// Returns `true` if the string contains "acquisition" (case-insensitive).
@objc public func TPPOPDSTypeStringIsAcquisitionSwift(_ string: String?) -> Bool {
  guard let string = string else { return false }
  return string.range(of: "acquisition", options: .caseInsensitive) != nil
}

/// Returns `true` if the string contains "navigation" (case-insensitive).
@objc public func TPPOPDSTypeStringIsNavigationSwift(_ string: String?) -> Bool {
  guard let string = string else { return false }
  return string.range(of: "navigation", options: .caseInsensitive) != nil
}

/// Returns `true` if the string contains "application/opensearchdescription+xml" (case-insensitive).
@objc public func TPPOPDSTypeStringIsOpenSearchDescriptionSwift(_ string: String?) -> Bool {
  guard let string = string else { return false }
  return string.range(of: "application/opensearchdescription+xml", options: .caseInsensitive) != nil
}
