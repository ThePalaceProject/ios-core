import Foundation

/**
 Represents a Problem Document, outlined in https://tools.ietf.org/html/rfc7807
 */
@objcMembers class TPPProblemDocument: NSObject, Codable {
    static let TypeNoActiveLoan =
        "http://librarysimplified.org/terms/problem/no-active-loan"
    static let TypeLoanAlreadyExists =
        "http://librarysimplified.org/terms/problem/loan-already-exists"
    static let TypeInvalidCredentials =
        "http://librarysimplified.org/terms/problem/credentials-invalid"
    static let TypeCannotFulfillLoan =
        "http://librarysimplified.org/terms/problem/cannot-fulfill-loan"
    static let TypeCannotIssueLoan =
        "http://librarysimplified.org/terms/problem/cannot-issue-loan"
    static let TypeCannotRender =
        "http://librarysimplified.org/terms/problem/cannot-render"

    // MARK: - Account/Patron Status Types

    /// Patron's credentials have been suspended by the library
    static let TypeCredentialsSuspended =
        "http://librarysimplified.org/terms/problem/credentials-suspended"

    /// Patron has reached their loan limit
    static let TypePatronLoanLimit =
        "http://librarysimplified.org/terms/problem/loan-limit-reached"

    /// Patron has reached their hold limit
    static let TypePatronHoldLimit =
        "http://librarysimplified.org/terms/problem/hold-limit-reached"

    /// Feedbooks/LCP: DRM license term limit reached; the loan is already expired server-side.
    /// Appears in the `detail` field of a 500 problem document returned by the revoke endpoint.
    static let DetailLoanTermLimitReached = "loan_term_limit_reached"

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

    private init(_ dict: [String: Any]) {
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
    static func fromData(_ data: Data) throws -> TPPProblemDocument {
        let jsonDecoder = JSONDecoder()
        jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase

        do {
            return try jsonDecoder.decode(TPPProblemDocument.self, from: data)
        } catch {
            // The server may return duplicated JSON (two concatenated objects).
            // Extract and parse just the first well-formed JSON object.
            if let firstObjectData = extractFirstJSONObject(from: data),
               firstObjectData.count < data.count {
                return try jsonDecoder.decode(TPPProblemDocument.self, from: firstObjectData)
            }
            throw error
        }
    }

    /// Extracts the first top-level JSON object (`{...}`) from data that may
    /// contain concatenated objects (a known server bug where the response body
    /// is duplicated).
    private static func extractFirstJSONObject(from data: Data) -> Data? {
        guard let string = String(data: data, encoding: .utf8) else { return nil }

        var depth = 0
        var inString = false
        var escaped = false

        for (offset, char) in string.unicodeScalars.enumerated() {
            if escaped { escaped = false; continue }
            if char == "\\" && inString { escaped = true; continue }
            if char == "\"" { inString = !inString; continue }
            if inString { continue }

            if char == "{" { depth += 1 }
            if char == "}" {
                depth -= 1
                if depth == 0 {
                    let endIndex = string.index(string.startIndex, offsetBy: offset + 1)
                    return String(string[..<endIndex]).data(using: .utf8)
                }
            }
        }
        return nil
    }

    /// When the server returns application/api-problem+json but strict RFC 7807 decode fails,
    /// extracts a human-readable message from common keys so the user still sees the server's reason.
    static func fromProblemResponseData(_ data: Data) -> TPPProblemDocument? {
        if let doc = try? fromData(data) {
            return doc
        }
        let parseableData = extractFirstJSONObject(from: data) ?? data
        guard let dict = (try? JSONSerialization.jsonObject(with: parseableData)) as? [String: Any] else {
            return nil
        }
        let detail = (dict["detail"] as? String)
            ?? (dict["message"] as? String)
            ?? (dict["title"] as? String)
        let title = dict["title"] as? String
        return TPPProblemDocument([
            typeKey: dict["type"] as? String ?? "",
            titleKey: title ?? NSLocalizedString("Download Error", comment: ""),
            statusKey: dict["status"] as? Int ?? noStatus,
            detailKey: detail ?? NSLocalizedString("The server returned an error. You may need to return the book and borrow it again.", comment: ""),
            instanceKey: dict["instance"] as? String ?? ""
        ])
    }

    /// Factory method to create a problem document after an api call.
    ///
    /// - Parameters:
    ///   - responseData: Response data possibly containing a problem document.
    ///   - responseError: Error possibly containing a problem document.
    /// - Returns: A problem document instance if a problem document was found,
    /// or `nil` otherwise.
    class func fromResponseError(_ responseError: NSError?,
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
    static func fromDictionary(_ dict: [String: Any]) -> TPPProblemDocument {
        return TPPProblemDocument(dict)
    }

    @objc var dictionaryValue: [String: Any] {
        return [
            TPPProblemDocument.typeKey: type ?? "",
            TPPProblemDocument.titleKey: title ?? "",
            TPPProblemDocument.statusKey: status ?? TPPProblemDocument.noStatus,
            TPPProblemDocument.detailKey: detail ?? "",
            TPPProblemDocument.instanceKey: instance ?? ""
        ]
    }

    @objc var stringValue: String {
        return "\(title == nil ? "" : title! + ": ")\(detail ?? "")"
    }

    // MARK: - Auth Error Categories

    /// URL path component indicating a recoverable auth error.
    /// Server uses: http://palaceproject.io/terms/problem/auth/recoverable/*
    private static let recoverableAuthPath = "/auth/recoverable/"

    /// URL path component indicating an unrecoverable auth error.
    /// Server uses: http://palaceproject.io/terms/problem/auth/unrecoverable/*
    private static let unrecoverableAuthPath = "/auth/unrecoverable/"

    /// Returns true if this is a recoverable auth error.
    /// Client should re-authenticate (restart auth flow for the appropriate auth type).
    ///
    /// Examples:
    /// - Token expired/invalid → request new token
    /// - SAML session expired → re-authenticate via IdP
    /// - SAML bearer token invalid → restart SAML flow
    var isRecoverableAuthError: Bool {
        guard let type = type else { return false }
        return type.contains(TPPProblemDocument.recoverableAuthPath)
    }

    /// Returns true if this is an unrecoverable auth error.
    /// Client should display the error to the user (re-auth won't help).
    ///
    /// Examples:
    /// - Invalid credentials (wrong username/password)
    /// - No access (user doesn't have library access)
    /// - Cannot identify patron (server config issue)
    var isUnrecoverableAuthError: Bool {
        guard let type = type else { return false }
        return type.contains(TPPProblemDocument.unrecoverableAuthPath)
    }
}
