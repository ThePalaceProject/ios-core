import Foundation

/**
 Represents a Problem Document, outlined in https://tools.ietf.org/html/rfc7807
 */
@objcMembers class TPPProblemDocument: NSObject, Codable {
  static let TypeNoActiveLoan =
    "http://librarysimplified.org/terms/problem/no-active-loan";
  static let TypeLoanAlreadyExists =
    "http://librarysimplified.org/terms/problem/loan-already-exists";
  static let TypeInvalidCredentials =
    "http://librarysimplified.org/terms/problem/credentials-invalid";
  static let TypeCannotFulfillLoan =
    "http://librarysimplified.org/terms/problem/cannot-fulfill-loan";
  static let TypeCannotIssueLoan =
    "http://librarysimplified.org/terms/problem/cannot-issue-loan";
  static let TypeCannotRender =
    "http://librarysimplified.org/terms/problem/cannot-render";
  
  // MARK: - Account/Patron Status Types
  
  /// Patron's credentials have been suspended by the library
  static let TypeCredentialsSuspended =
    "http://librarysimplified.org/terms/problem/credentials-suspended";
  
  /// Patron has reached their loan limit
  static let TypePatronLoanLimit =
    "http://librarysimplified.org/terms/problem/loan-limit-reached";
  
  /// Patron has reached their hold limit
  static let TypePatronHoldLimit =
    "http://librarysimplified.org/terms/problem/hold-limit-reached";

  private static let noStatus: Int = -1

  private static let typeKey = "type"
  private static let titleKey = "title"
  private static let statusKey = "status"
  private static let detailKey = "detail"
  private static let instanceKey = "instance"

  /// Per RFC7807, this identifies the type of problem.
  let type: String?

  /// Per RFC7807, this is a short, human-readable summary of the problem.
  let title: String?

  /// Per RFC7807, this will match the HTTP status code.
  let status: Int?

  /// Per RFC7807, this is a human-readable explanation of the specific problem
  /// that occurred. It can also provide information to correct the problem.
  let detail: String?

  /// Per RFC7807, a URI reference that identifies the specific occurrence of
  /// the problem.
  let instance: String?
  
  private init(_ dict: [String : Any]) {
    self.type = dict[TPPProblemDocument.typeKey] as? String
    self.title = dict[TPPProblemDocument.titleKey] as? String
    self.status = dict[TPPProblemDocument.statusKey] as? Int
    self.detail = dict[TPPProblemDocument.detailKey] as? String
    self.instance = dict[TPPProblemDocument.instanceKey] as? String
    super.init()
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
  static func forExpiredOrMissingCredentials(hasCredentials: Bool) -> TPPProblemDocument {
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

  /**
    Factory method that creates a ProblemDocument from data
    @param data data with which to populate the ProblemDocument
    @return a ProblemDocument built from the given data
   */
  @objc static func fromData(_ data: Data) throws -> TPPProblemDocument {
    let jsonDecoder = JSONDecoder()
    jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
    
    return try jsonDecoder.decode(TPPProblemDocument.self, from: data)
  }
  
  /// Factory method to create a problem document after an api call.
  ///
  /// - Parameters:
  ///   - responseData: Response data possibly containing a problem document.
  ///   - responseError: Error possibly containing a problem document.
  /// - Returns: A problem document instance if a problem document was found,
  /// or `nil` otherwise.
  @objc class func fromResponseError(_ responseError: NSError?,
                                     responseData: Data?) -> TPPProblemDocument? {
    if let problemDocFromError = responseError?.problemDocument {
      return problemDocFromError
    } else if let responseData = responseData {
      return try? TPPProblemDocument.fromData(responseData)
    }
      return nil
  }

  /**
    Factory method that creates a ProblemDocument from a dictionary
    @param dict data with which to populate the ProblemDocument
    @return a ProblemDocument built from the given dicationary
   */
  @objc static func fromDictionary(_ dict: [String : Any]) -> TPPProblemDocument {
    return TPPProblemDocument(dict)
  }

  @objc var dictionaryValue: [String: Any] {
    return [
      TPPProblemDocument.typeKey: type ?? "",
      TPPProblemDocument.titleKey: title ?? "",
      TPPProblemDocument.statusKey: status ?? TPPProblemDocument.noStatus,
      TPPProblemDocument.detailKey: detail ?? "",
      TPPProblemDocument.instanceKey: instance ?? "",
    ]
  }

  @objc var stringValue: String {
    return "\(title == nil ? "" : title! + ": ")\(detail ?? "")"
  }
}
