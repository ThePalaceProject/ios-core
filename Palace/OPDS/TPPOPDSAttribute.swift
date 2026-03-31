import Foundation

@objc func TPPOPDSAttributeKeyStringIsActiveFacet(_ string: String?) -> Bool {
  guard let string = string else { return false }
  return string.range(of: "activeFacet", options: .caseInsensitive) != nil
}

@objc func TPPOPDSAttributeKeyStringIsFacetGroup(_ string: String?) -> Bool {
  guard let string = string else { return false }
  return string.range(of: "facetGroup", options: .caseInsensitive) != nil
}

@objc func TPPOPDSAttributeKeyStringIsFacetGroupType(_ string: String?) -> Bool {
  guard let string = string else { return false }
  return string.range(of: "facetGroupType", options: .caseInsensitive) != nil
}
