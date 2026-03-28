import Foundation

// MARK: - OPDS Type Functions (Swift port of TPPOPDSType.m)

@objcMembers
class TPPOPDSTypeHelper: NSObject {
  /// Returns `true` if the string contains "acquisition" (case-insensitive).
  static func stringIsAcquisition(_ string: String?) -> Bool {
    guard let string = string else { return false }
    return string.range(of: "acquisition", options: .caseInsensitive) != nil
  }

  /// Returns `true` if the string contains "navigation" (case-insensitive).
  static func stringIsNavigation(_ string: String?) -> Bool {
    guard let string = string else { return false }
    return string.range(of: "navigation", options: .caseInsensitive) != nil
  }

  /// Returns `true` if the string contains "application/opensearchdescription+xml" (case-insensitive).
  static func stringIsOpenSearchDescription(_ string: String?) -> Bool {
    guard let string = string else { return false }
    return string.range(of: "application/opensearchdescription+xml", options: .caseInsensitive) != nil
  }
}
