import Foundation
import PalaceCatalog

extension TPPProblemDocument {
    /// Factory method to create a problem document after an api call.
    @nonobjc public class func fromResponseError(_ responseError: NSError?,
                                        responseData: Data?) -> TPPProblemDocument? {
        if let problemDocFromError = responseError?.problemDocument {
            return problemDocFromError
        } else if let responseData = responseData {
            return try? TPPProblemDocument.fromData(responseData)
        }
        return nil
    }

    /// Synthesizes a problem document for expired or missing credentials.

    @nonobjc public static func forExpiredOrMissingCredentials(hasCredentials: Bool) -> TPPProblemDocument {
        let title: String
        let detail: String
        if hasCredentials {
            title = Strings.TPPProblemDocument.authenticationExpiredTitle
            detail = Strings.TPPProblemDocument.authenticationExpiredBody
        } else {
            title = Strings.TPPProblemDocument.authenticationRequiredTitle
            detail = Strings.TPPProblemDocument.authenticationRequireBody
        }
        return TPPProblemDocument.fromDictionary([
            "type": TPPProblemDocument.TypeInvalidCredentials,
            "title": title,
            "detail": detail,
        ])
    }
}
