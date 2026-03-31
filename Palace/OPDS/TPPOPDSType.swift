import Foundation

// MARK: - OPDS Type Functions (Swift port of TPPOPDSType.m)

/// Returns `true` if the string contains "acquisition" (case-insensitive).
public func TPPOPDSTypeStringIsAcquisition(_ string: String?) -> Bool {
  guard let string = string else { return false }
  return string.range(of: "acquisition", options: .caseInsensitive) != nil
}

/// Returns `true` if the string contains "navigation" (case-insensitive).
public func TPPOPDSTypeStringIsNavigation(_ string: String?) -> Bool {
  guard let string = string else { return false }
  return string.range(of: "navigation", options: .caseInsensitive) != nil
}

/// Returns `true` if the string contains "application/opensearchdescription+xml" (case-insensitive).
public func TPPOPDSTypeStringIsOpenSearchDescription(_ string: String?) -> Bool {
  guard let string = string else { return false }
  return string.range(of: "application/opensearchdescription+xml", options: .caseInsensitive) != nil
}
