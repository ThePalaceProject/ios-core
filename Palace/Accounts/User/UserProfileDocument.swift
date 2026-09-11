import Foundation

@objcMembers public class UserProfileDocument: NSObject, Codable {
    static let parseErrorKey: String = "TPPParseProfileErrorKey"
    static let parseErrorDescription: String = "TPPParseProfileErrorDescription"
    static let parseErrorCodingPath: String = "TPPParseProfileErrorCodingPath"

    @objc @objcMembers public class DRMObject: NSObject, Codable {
        let vendor: String?
        let clientToken: String?
        let serverToken: String?
        let scheme: String?

        var licensor: [String: String] {
            return [
                "vendor": vendor ?? "",
                "clientToken": clientToken ?? ""
            ]
        }

        enum CodingKeys: String, CodingKey {
            case vendor  = "drm:vendor"
            case clientToken = "drm:clientToken"
            case serverToken = "drm:serverToken"
            case scheme = "drm:scheme"
        }
    }

    @objc public class Link: NSObject, Codable {
        let href: String
        let type: String?
        let rel: String?
        let templated: Bool?
    }

    @objc public class Settings: NSObject, Codable {
        let synchronizeAnnotations: Bool?

        enum CodingKeys: String, CodingKey {
            case synchronizeAnnotations  = "simplified:synchronize_annotations"
        }
    }

    let authorizationIdentifier: String?
    let drm: [DRMObject]?
    let links: [Link]?
    let authorizationExpires: Date?
    let settings: Settings?

    private static var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    enum CodingKeys: String, CodingKey {
        case authorizationIdentifier = "simplified:authorization_identifier"
        case drm = "drm"
        case links = "links"
        case authorizationExpires = "simplified:authorization_expires"
        case settings = "settings"
    }

    /// A description of this document safe to write to a persisted log.
    ///
    /// `toJson()` is NOT. `Log.error`/`Log.fault` are appended to
    /// `Documents/Logs/palace_error.log`, which the patron can export and
    /// routinely attaches to support tickets, and the encoded document carries
    /// `simplified:authorization_identifier` — the patron's BARCODE — and
    /// `drm:clientToken`, a credential Adobe accepts for its 60-minute window.
    ///
    /// Everything a reader of that log actually asks of this value survives:
    /// which fields arrived, how many DRM entries there are, which vendor,
    /// which library minted the token and when it dies. Only the barcode and
    /// the token's signature are withheld — and their PRESENCE and LENGTH are
    /// still reported, because "absent" and "present but wrong" are different
    /// defects and collapsing them is how a malformed value reads as a missing
    /// one.
    var loggableSummary: String {
        let identifier = authorizationIdentifier.map { "present (\($0.count) chars)" } ?? "absent"
        let expires = authorizationExpires.map(ISO8601DateFormatter().string(from:)) ?? "absent"

        let drmSummary: String
        if let drm, !drm.isEmpty {
            drmSummary = drm.map { entry in
                let vendor = entry.vendor.flatMap { $0.isEmpty ? nil : $0 } ?? "absent"
                let serverToken = (entry.serverToken?.isEmpty == false) ? "present" : "absent"
                return "{vendor: \(vendor), scheme: \(entry.scheme ?? "absent"), "
                     + "clientToken: \(AdobeClientToken.redacted(entry.clientToken)), "
                     + "serverToken: \(serverToken)}"
            }.joined(separator: ", ")
        } else {
            drmSummary = drm == nil ? "absent" : "empty"
        }

        return "UserProfileDocument(authorizationIdentifier: \(identifier), "
             + "authorizationExpires: \(expires), "
             + "settings.synchronizeAnnotations: \(settings?.synchronizeAnnotations.map(String.init) ?? "absent"), "
             + "links: \(links?.count ?? 0), drm: [\(drmSummary)])"
    }

    func toJson() -> String {
        let jsonEncoder = JSONEncoder()
        let jsonData = try? jsonEncoder.encode(self)
        if let jsonData = jsonData {
            return String(data: jsonData, encoding: .utf8) ?? ""
        }
        return ""
    }

    static func fromData(_ data: Data) throws -> UserProfileDocument {
        let jsonDecoder = JSONDecoder()
        jsonDecoder.keyDecodingStrategy = .useDefaultKeys
        jsonDecoder.dateDecodingStrategy = .formatted(dateFormatter)

        do {
            return try jsonDecoder.decode(UserProfileDocument.self, from: data)
        } catch let DecodingError.dataCorrupted(context) {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSCoderReadCorruptError,
                          userInfo: [parseErrorKey: TPPErrorCode.parseProfileDataCorrupted.rawValue,
                                     parseErrorDescription: context.debugDescription,
                                     parseErrorCodingPath: context.codingPath])
        } catch let DecodingError.typeMismatch(_, context) {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSCoderReadCorruptError,
                          userInfo: [parseErrorKey: TPPErrorCode.parseProfileTypeMismatch.rawValue,
                                     parseErrorDescription: context.debugDescription,
                                     parseErrorCodingPath: context.codingPath])
        } catch let DecodingError.valueNotFound(_, context) {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSCoderValueNotFoundError,
                          userInfo: [parseErrorKey: TPPErrorCode.parseProfileValueNotFound.rawValue,
                                     parseErrorDescription: context.debugDescription,
                                     parseErrorCodingPath: context.codingPath])
        } catch let DecodingError.keyNotFound(_, context) {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSCoderValueNotFoundError,
                          userInfo: [parseErrorKey: TPPErrorCode.parseProfileKeyNotFound.rawValue,
                                     parseErrorDescription: context.debugDescription,
                                     parseErrorCodingPath: context.codingPath])
        }
    }
}
