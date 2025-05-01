import Foundation
import ReadiumShared
import ReadiumStreamer

let RIGHTS_XML_SUFFIX = "_rights.xml"

/// A “no-op” fulfiller (rights already embedded) and a Readium ContentProtection
/// hook that forwards Adobe DRM calls into our ObjC++ bridge.
class AdobeDRMLibraryService: DRMLibraryService {

  // This is what Readium Navigator/Streamer uses to decrypt each resource.
  var contentProtection: ContentProtection? = AdobeDRMContentProtection()

  /// We only “fulfill” rights-XML files, so if the URL ends in “_rights.xml” we own it.
  func canFulfill(_ file: URL) -> Bool {
    return file.path.hasSuffix(RIGHTS_XML_SUFFIX)
  }

  /// No network round-trip: the EPUB has already been downloaded at
  /// “book.epub_rights.xml” → “book.epub”. We simply hand back the local URL.
  func fulfill(_ file: URL) async throws -> DRMFulfilledPublication {
    return DRMFulfilledPublication(
      localURL: file,
      suggestedFilename: file.lastPathComponent
    )
  }
}
