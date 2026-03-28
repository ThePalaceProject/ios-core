import Foundation

// MARK: - OPDS Attribute Functions (Swift port of TPPOPDSAttribute.m)

/// Returns `true` if the string contains "activeFacet" (case-insensitive).
public func TPPOPDSAttributeKeyStringIsActiveFacetSwift(_ string: String?) -> Bool {
  guard let string = string else { return false }
  return string.range(of: "activeFacet", options: .caseInsensitive) != nil
}

/// Returns `true` if the string contains "facetGroup" (case-insensitive).
public func TPPOPDSAttributeKeyStringIsFacetGroupSwift(_ string: String?) -> Bool {
  guard let string = string else { return false }
  return string.range(of: "facetGroup", options: .caseInsensitive) != nil
}

/// Returns `true` if the string contains "facetGroupType" (case-insensitive).
public func TPPOPDSAttributeKeyStringIsFacetGroupTypeSwift(_ string: String?) -> Bool {
  guard let string = string else { return false }
  return string.range(of: "facetGroupType", options: .caseInsensitive) != nil
}
