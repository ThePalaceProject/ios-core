import Foundation

func TPPOPDSTypeStringIsAcquisition(_ string: String?) -> Bool {
  guard let string = string else { return false }
  return string.range(of: "acquisition", options: .caseInsensitive) != nil
}

func TPPOPDSTypeStringIsNavigation(_ string: String?) -> Bool {
  guard let string = string else { return false }
  return string.range(of: "navigation", options: .caseInsensitive) != nil
}

func TPPOPDSTypeStringIsOpenSearchDescription(_ string: String?) -> Bool {
  guard let string = string else { return false }
  return string.range(of: "application/opensearchdescription+xml", options: .caseInsensitive) != nil
}
