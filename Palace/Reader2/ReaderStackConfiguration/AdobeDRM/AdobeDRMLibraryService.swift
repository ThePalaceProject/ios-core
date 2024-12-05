import Foundation
import UIKit
import ReadiumShared
import ReadiumStreamer

#if FEATURE_DRM_CONNECTOR

class AdobeDRMLibraryService: DRMLibraryService {

  var contentProtection: ContentProtection? = AdobeDRMContentProtection()

  /// Returns whether this DRM can fulfill the given file into a protected publication.
  /// - Parameter file: file URL
  /// - Returns: `true` if file contains Adobe DRM license information.
  func canFulfill(_ file: URL) -> Bool {
    return file.path.hasSuffix(RIGHTS_XML_SUFFIX)
  }

  /// Fulfills the given file to the fully protected publication.
  /// - Parameter file: file URL
  /// - Returns: The fulfilled publication or an error
  func fulfill(_ file: URL) async throws -> DRMFulfilledPublication {
    // Publications with Adobe DRM are fulfilled (license data already stored in _rights.xml file),
    // this step is always a success.
    return DRMFulfilledPublication(
      localURL: file,
      suggestedFilename: file.lastPathComponent
    )
  }
}

#endif
