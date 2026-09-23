import Foundation
import PalaceLogging

/**
 Represents a Problem Document, outlined in https://tools.ietf.org/html/rfc7807
 */
// Sendable: `final` + every stored property is an immutable `let` of a Sendable
// value type (String?/Int?/Bool?). The APIs that return mutable shapes
// (`dictionaryValue`, `stringValue`) are computed and build fresh values per call.
// NSObject is an allowed superclass for a checked Sendable conformance.
@objcMembers public final class TPPProblemDocument: NSObject, Codable, Sendable {
    public static let TypeNoActiveLoan =
        "http://librarysimplified.org/terms/problem/no-active-loan"
    public static let TypeLoanAlreadyExists =
        "http://librarysimplified.org/terms/problem/loan-already-exists"
    public static let TypeInvalidCredentials =
        "http://librarysimplified.org/terms/problem/credentials-invalid"
    public static let TypeCannotFulfillLoan =
        "http://librarysimplified.org/terms/problem/cannot-fulfill-loan"
    public static let TypeCannotIssueLoan =
        "http://librarysimplified.org/terms/problem/cannot-issue-loan"
    public static let TypeCannotRender =
        "http://librarysimplified.org/terms/problem/cannot-render"

    // MARK: - Account/Patron Status Types

    /// Patron's credentials have been suspended by the library
    public static let TypeCredentialsSuspended =
        "http://librarysimplified.org/terms/problem/credentials-suspended"

    /// Patron has reached their loan limit
    public static let TypePatronLoanLimit =
        "http://librarysimplified.org/terms/problem/loan-limit-reached"

    /// Patron has reached their hold limit
    public static let TypePatronHoldLimit =
        "http://librarysimplified.org/terms/problem/hold-limit-reached"

    /// Feedbooks/LCP: DRM license term limit reached; the loan is already expired server-side.
    /// Appears in the `detail` field of a 500 problem document returned by the revoke endpoint.
    public static let DetailLoanTermLimitReached = "loan_term_limit_reached"

    private static let noStatus: Int = -1

    private static let typeKey = "type"
    private static let titleKey = "title"
    private static let statusKey = "status"
    private static let detailKey = "detail"
    private static let instanceKey = "instance"
    private static let showTitleKey = "show_title"

    /// Per RFC7807, this identifies the type of problem.
    public let type: String?

    /// Per RFC7807, this is a short, human-readable summary of the problem.
    public let title: String?

    /// Per RFC7807, this will match the HTTP status code.
    public let status: Int?

    /// Per RFC7807, this is a human-readable explanation of the specific problem
    /// that occurred. It can also provide information to correct the problem.
    public let detail: String?

    /// Per RFC7807, a URI reference that identifies the specific occurrence of
    /// the problem.
    public let instance: String?

    /// Palace extension (`show_title`): whether the client should display a
    /// title alongside `detail`. The server sends `false` when `detail` is
    /// meant to stand on its own — e.g. a library's patron-blocking-rule
    /// message that redirects the patron to a different library, where the
    /// standard "Blocked by library policy." title is unwanted framing.
    ///
    /// `nil` when the server did not send the member, which is the common
    /// case; prefer `shouldShowTitle` over reading this directly.
    // PUBLIC_INTENT: contracted SPM API. `TPPProblemDocument` is PalaceCatalog's public
    // RFC 7807 model; every other member is already `public` and main-target consumers
    // (sign-in, borrow, download) read them directly. An `internal` member here would be
    // invisible to them.
    public let showTitle: Bool?

    /// Whether to display a title with this problem's `detail`. Defaults to
    /// `true` when the server sent no `show_title`, so documents that predate
    /// the extension keep displaying a title as they always have.
    // PUBLIC_INTENT: the sentinel half of this type's title contract, read by
    // `TPPSignInBusinessLogic.userFacingSignInError` in the main target, so it must
    // be as visible as `shouldShowTitle` itself.
    /// The title value meaning "render no title at all". Deliberately distinct from
    /// `nil`, which means "the server supplied none" and lets the display layer
    /// substitute its own ("Login Failed") — precisely the framing that
    /// `show_title: false` exists to suppress.
    public static let suppressedTitle = ""

    // PUBLIC_INTENT: the accessor consumers are meant to use instead of `showTitle`, so it
    // must be at least as visible as the member it wraps. `TPPSignInBusinessLogic`
    // .userFacingSignInError reads it from the main target.
    public var shouldShowTitle: Bool {
        showTitle ?? true
    }

    // MARK: - Decoding

    // Declared explicitly so `showTitle` can be decoded LENIENTLY while the five
    // RFC 7807 members keep the strict behavior synthesized `Codable` gave them.
    //
    // The raw values are CAMELCASE ON PURPOSE. `fromData` sets
    // `.convertFromSnakeCase`, which rewrites the incoming JSON key `show_title`
    // to `showTitle` BEFORE it is matched against these cases. A case spelled
    // `showTitle = "show_title"` would therefore match NOTHING — the flag would be
    // silently unreadable even for a perfectly well-formed `{"show_title": false}`,
    // with no throw to reveal it. Measured; see the tests in `ProblemDocumentTests`.
    private enum CodingKeys: String, CodingKey {
        case type, title, status, detail, instance, showTitle
    }

    /// Decodes the five RFC 7807 members strictly and `show_title` leniently.
    ///
    /// Synthesized `Codable` generates `decodeIfPresent` per member, which returns
    /// `nil` only for an ABSENT or `null` value — a present-but-wrong-typed value
    /// throws `typeMismatch` and aborts the WHOLE decode. That is why declaring
    /// `showTitle` at all was a hazard: before it existed, `show_title` was an
    /// unknown key and was ignored whatever its type; after, a server sending
    /// `"show_title": "false"` or `0` would cost us the entire document.
    ///
    /// On the sign-in path that is not a cosmetic loss. `TPPNetworkResponder`
    /// parses with the strict `fromData`, and its `catch` arm returns an `NSError`
    /// carrying no problem document — so `userFacingSignInError` receives `nil`,
    /// skips the branch that honors `show_title`, and falls through to "invalid
    /// credentials". A patron blocked by a library policy would be told their
    /// password is wrong, and the library's `detail` would never render.
    ///
    /// So the flag is allowed to fail, and the document is not: an unreadable
    /// `show_title` degrades to "the server sent no flag", which `shouldShowTitle`
    /// already treats as "show the title" — the pre-extension behavior.
    // PUBLIC_INTENT: `Decodable` conformance is already public on this type, so
    // `init(from:)` is public API whether written by hand or synthesized — declaring it
    // explicitly widens nothing. Swift additionally requires the witness to be at least as
    // visible as the conformance, so `internal` would not compile.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type     = try container.decodeIfPresent(String.self, forKey: .type)
        self.title    = try container.decodeIfPresent(String.self, forKey: .title)
        self.status   = try container.decodeIfPresent(Int.self,    forKey: .status)
        self.detail   = try container.decodeIfPresent(String.self, forKey: .detail)
        self.instance = try container.decodeIfPresent(String.self, forKey: .instance)

        // `do`/`catch`, NOT `try?`: `try?` collapses absent, `null` and threw into a
        // single `nil`, and we need to tell "the server sent nothing" (routine, and
        // silent) from "the server sent something we could not read" (a
        // misconfiguration worth a line in the log).
        //
        // `container.contains(.showTitle)` is NOT a substitute — it is `true` for an
        // explicit `null`, so gating the warning on it would fire on
        // `{"show_title": null}`, which is a legitimate body. This `catch` is entered
        // for a type mismatch and nothing else.
        do {
            self.showTitle = try container.decodeIfPresent(Bool.self, forKey: .showTitle)
        } catch {
            Log.warn(#file, "Problem document sent `show_title` as a non-boolean; ignoring the flag and showing the title. Decoding error: \(error)")
            self.showTitle = nil
        }

        super.init()
    }

    // No custom `encode(to:)` — deliberately. The synthesized encoder against these
    // camelCase keys already round-trips through `init(from:)` with a PLAIN
    // `JSONDecoder`. A hand-written encoder emitting `show_title` would BREAK that,
    // because `init(from:)` keys on the post-strategy camelCase name: the flag would
    // survive a `.convertFromSnakeCase` decoder and be silently lost by every other
    // one. Both round trips are pinned in `ProblemDocumentTests`.

    private init(_ dict: [String: Any]) {
        self.type = dict[TPPProblemDocument.typeKey] as? String
        self.title = dict[TPPProblemDocument.titleKey] as? String
        self.status = dict[TPPProblemDocument.statusKey] as? Int
        self.detail = dict[TPPProblemDocument.detailKey] as? String
        self.instance = dict[TPPProblemDocument.instanceKey] as? String
        self.showTitle = dict[TPPProblemDocument.showTitleKey] as? Bool
        super.init()
    }

    /**
     Factory method that creates a ProblemDocument from data
     @param data data with which to populate the ProblemDocument
     @return a ProblemDocument built from the given data
     */
    public static func fromData(_ data: Data) throws -> TPPProblemDocument {
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
    public static func fromProblemResponseData(_ data: Data) -> TPPProblemDocument? {
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
        var members: [String: Any] = [
            typeKey: dict["type"] as? String ?? "",
            titleKey: title ?? NSLocalizedString("Download Error", comment: ""),
            statusKey: dict["status"] as? Int ?? noStatus,
            detailKey: detail ?? NSLocalizedString("The server returned an error. You may need to return the book and borrow it again.", comment: ""),
            instanceKey: dict["instance"] as? String ?? ""
        ]
        if let showTitle = dict[showTitleKey] as? Bool {
            members[showTitleKey] = showTitle
        }
        return TPPProblemDocument(members)
    }

    /**
     Factory method that creates a ProblemDocument from a dictionary
     @param dict data with which to populate the ProblemDocument
     @return a ProblemDocument built from the given dicationary
     */
    public static func fromDictionary(_ dict: [String: Any]) -> TPPProblemDocument {
        return TPPProblemDocument(dict)
    }

    @objc public var dictionaryValue: [String: Any] {
        var dict: [String: Any] = [
            TPPProblemDocument.typeKey: type ?? "",
            TPPProblemDocument.titleKey: title ?? "",
            TPPProblemDocument.statusKey: status ?? TPPProblemDocument.noStatus,
            TPPProblemDocument.detailKey: detail ?? "",
            TPPProblemDocument.instanceKey: instance ?? ""
        ]
        // Only present when the server sent it, so documents without the
        // extension keep the dictionary shape every existing consumer sees.
        if let showTitle {
            dict[TPPProblemDocument.showTitleKey] = showTitle
        }
        return dict
    }

    @objc public var stringValue: String {
        return "\(title.map { $0 + ": " } ?? "")\(detail ?? "")"
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
    public var isRecoverableAuthError: Bool {
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
    public var isUnrecoverableAuthError: Bool {
        guard let type = type else { return false }
        return type.contains(TPPProblemDocument.unrecoverableAuthPath)
    }
}
