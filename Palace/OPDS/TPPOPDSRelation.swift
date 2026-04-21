import Foundation

@objc class TPPOPDSRelationConstants: NSObject {
  @objc static let acquisition = "http://opds-spec.org/acquisition"
  @objc static let acquisitionOpenAccess = "http://opds-spec.org/acquisition/open-access"
  @objc static let acquisitionBorrow = "http://opds-spec.org/acquisition/borrow"
  @objc static let acquisitionRevoke = "http://librarysimplified.org/terms/rel/revoke"
  @objc static let acquisitionSample = "http://opds-spec.org/acquisition/sample"
  @objc static let facet = "http://opds-spec.org/facet"
  @objc static let featured = "http://opds-spec.org/featured"
  @objc static let group = "collection"
  @objc static let image = "http://opds-spec.org/image"
  @objc static let imageThumbnail = "http://opds-spec.org/image/thumbnail"
  @objc static let paginationNext = "next"
  @objc static let search = "search"
  @objc static let subsection = "subsection"
  @objc static let eulaLink = "terms-of-service"
  @objc static let privacyPolicyLink = "privacy-policy"
  @objc static let acknowledgmentsLink = "copyright"
  @objc static let contentLicenseLink = "license"
  @objc static let acquisitionIssues = "issues"
  @objc static let preview = "preview"
  @objc static let annotations = "http://www.w3.org/ns/oa#annotationService"
  @objc static let entrypoint = "http://librarysimplified.org/terms/rel/entrypoint"
  @objc static let timeTrackingLink = "http://palaceproject.io/terms/timeTracking"
}

// Keep backward-compatible C-style constants for existing ObjC code
let TPPOPDSRelationAcquisition = TPPOPDSRelationConstants.acquisition
let TPPOPDSRelationAcquisitionOpenAccess = TPPOPDSRelationConstants.acquisitionOpenAccess
let TPPOPDSRelationAcquisitionBorrow = TPPOPDSRelationConstants.acquisitionBorrow
let TPPOPDSRelationAcquisitionRevoke = TPPOPDSRelationConstants.acquisitionRevoke
let TPPOPDSRelationAcquisitionSample = TPPOPDSRelationConstants.acquisitionSample
let TPPOPDSRelationFacet = TPPOPDSRelationConstants.facet
let TPPOPDSRelationFeatured = TPPOPDSRelationConstants.featured
let TPPOPDSRelationGroup = TPPOPDSRelationConstants.group
let TPPOPDSRelationImage = TPPOPDSRelationConstants.image
let TPPOPDSRelationImageThumbnail = TPPOPDSRelationConstants.imageThumbnail
let TPPOPDSRelationPaginationNext = TPPOPDSRelationConstants.paginationNext
let TPPOPDSRelationSearch = TPPOPDSRelationConstants.search
let TPPOPDSRelationSubsection = TPPOPDSRelationConstants.subsection
let TPPOPDSEULALink = TPPOPDSRelationConstants.eulaLink
let TPPOPDSPrivacyPolicyLink = TPPOPDSRelationConstants.privacyPolicyLink
let TPPOPDSAcknowledgmentsLink = TPPOPDSRelationConstants.acknowledgmentsLink
let TPPOPDSContentLicenseLink = TPPOPDSRelationConstants.contentLicenseLink
let TPPOPDSRelationAcquisitionIssues = TPPOPDSRelationConstants.acquisitionIssues
let TPPOPDSRelationPreview = TPPOPDSRelationConstants.preview
let TPPOPDSRelationAnnotations = TPPOPDSRelationConstants.annotations
let TPPOPDSRelationEntrypoint = TPPOPDSRelationConstants.entrypoint
let TPPOPDSRelationTimeTrackingLink = TPPOPDSRelationConstants.timeTrackingLink
