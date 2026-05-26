import Foundation

@objc public class TPPOPDSRelationConstants: NSObject {
  @objc public static let acquisition = "http://opds-spec.org/acquisition"
  @objc public static let acquisitionOpenAccess = "http://opds-spec.org/acquisition/open-access"
  @objc public static let acquisitionBorrow = "http://opds-spec.org/acquisition/borrow"
  @objc public static let acquisitionRevoke = "http://librarysimplified.org/terms/rel/revoke"
  @objc public static let acquisitionSample = "http://opds-spec.org/acquisition/sample"
  @objc public static let facet = "http://opds-spec.org/facet"
  @objc public static let featured = "http://opds-spec.org/featured"
  @objc public static let group = "collection"
  @objc public static let image = "http://opds-spec.org/image"
  @objc public static let imageThumbnail = "http://opds-spec.org/image/thumbnail"
  @objc public static let paginationNext = "next"
  @objc public static let search = "search"
  @objc public static let subsection = "subsection"
  @objc public static let eulaLink = "terms-of-service"
  @objc public static let privacyPolicyLink = "privacy-policy"
  @objc public static let acknowledgmentsLink = "copyright"
  @objc public static let contentLicenseLink = "license"
  @objc public static let acquisitionIssues = "issues"
  @objc public static let preview = "preview"
  @objc public static let annotations = "http://www.w3.org/ns/oa#annotationService"
  @objc public static let entrypoint = "http://librarysimplified.org/terms/rel/entrypoint"
  @objc public static let timeTrackingLink = "http://palaceproject.io/terms/timeTracking"
}

// Keep backward-compatible C-style constants for existing ObjC code
public let TPPOPDSRelationAcquisition = TPPOPDSRelationConstants.acquisition
public let TPPOPDSRelationAcquisitionOpenAccess = TPPOPDSRelationConstants.acquisitionOpenAccess
public let TPPOPDSRelationAcquisitionBorrow = TPPOPDSRelationConstants.acquisitionBorrow
public let TPPOPDSRelationAcquisitionRevoke = TPPOPDSRelationConstants.acquisitionRevoke
public let TPPOPDSRelationAcquisitionSample = TPPOPDSRelationConstants.acquisitionSample
public let TPPOPDSRelationFacet = TPPOPDSRelationConstants.facet
public let TPPOPDSRelationFeatured = TPPOPDSRelationConstants.featured
public let TPPOPDSRelationGroup = TPPOPDSRelationConstants.group
public let TPPOPDSRelationImage = TPPOPDSRelationConstants.image
public let TPPOPDSRelationImageThumbnail = TPPOPDSRelationConstants.imageThumbnail
public let TPPOPDSRelationPaginationNext = TPPOPDSRelationConstants.paginationNext
public let TPPOPDSRelationSearch = TPPOPDSRelationConstants.search
public let TPPOPDSRelationSubsection = TPPOPDSRelationConstants.subsection
public let TPPOPDSEULALink = TPPOPDSRelationConstants.eulaLink
public let TPPOPDSPrivacyPolicyLink = TPPOPDSRelationConstants.privacyPolicyLink
public let TPPOPDSAcknowledgmentsLink = TPPOPDSRelationConstants.acknowledgmentsLink
public let TPPOPDSContentLicenseLink = TPPOPDSRelationConstants.contentLicenseLink
public let TPPOPDSRelationAcquisitionIssues = TPPOPDSRelationConstants.acquisitionIssues
public let TPPOPDSRelationPreview = TPPOPDSRelationConstants.preview
public let TPPOPDSRelationAnnotations = TPPOPDSRelationConstants.annotations
public let TPPOPDSRelationEntrypoint = TPPOPDSRelationConstants.entrypoint
public let TPPOPDSRelationTimeTrackingLink = TPPOPDSRelationConstants.timeTrackingLink
