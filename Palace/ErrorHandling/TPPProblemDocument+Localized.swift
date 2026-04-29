import Foundation
import PalaceCatalog

extension TPPProblemDocument {
    /// Factory method to create a problem document after an api call.
    ///
    /// - Parameters:
    ///   - responseData: Response data possibly containing a problem document.
    ///   - responseError: Error possibly containing a problem document.
    /// - Returns: A problem document instance if a problem document was found,
    /// or `nil` otherwise.
    public class func fromResponseError(_ responseError: NSError?,
                                       responseData: Data?) -> TPPProblemDocument? {
        if let problemDocFromError = responseError?.problemDocument {
            return problemDocFromError
        } else if let responseData = responseData {
            return try? TPPProblemDocument.fromData(responseData)
        }
        return nil
    }

    /// Synthesizes a problem document for expired or missing credentials.
    ///
    /// The type will always be `TPPProblemDocument.TypeInvalidCredentials`.
    ///
    /// - Note: Use this sparingly. Problem Documents are by definition
    /// objects representing a server result. This is provided only to facilitate
    /// interfacing with existing logic that expects a problem document, but
    /// the problem originated on the client.
    ///
    /// - Parameter hasCredentials: if `true` the problem document will represent
    /// an expired credentials situation, otherwise the missing credentials case.
    /// - Returns: A problem document with `type`, `title`, `detail`.
    @objc(forExpiredOrMissingCredentials:)
    public static func forExpiredOrMissingCredentials(hasCredentials: Bool) -> TPPProblemDocument {
        if hasCredentials {
            return TPPProblemDocument([
                                        TPPProblemDocument.typeKey: TPPProblemDocument.TypeInvalidCredentials,
                                        TPPProblemDocument.titleKey:
                                            Strings.TPPProblemDocument.authenticationExpiredTitle,
                                        TPPProblemDocument.detailKey:
                                            Strings.TPPProblemDocument.authenticationExpiredBody])
        } else {
            return TPPProblemDocument([
                                        TPPProblemDocument.typeKey: TPPProblemDocument.TypeInvalidCredentials,
                                        TPPProblemDocument.titleKey: Strings.TPPProblemDocument.authenticationRequiredTitle,
                                        TPPProblemDocument.detailKey:
                                            Strings.TPPProblemDocument.authenticationRequireBody])
        }
    }
}
