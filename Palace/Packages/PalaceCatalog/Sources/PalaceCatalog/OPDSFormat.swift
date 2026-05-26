import Foundation

public enum OPDSFormat: String, Sendable {
    case opds2 = "application/opds+json"
    case opds1 = "application/atom+xml"
    case unknown

    public static func detect(from contentType: String?) -> OPDSFormat {
        guard let contentType = contentType?.lowercased() else { return .unknown }

        if contentType.contains("json") || contentType.contains("opds+json") {
            return .opds2
        } else if contentType.contains("xml") || contentType.contains("atom") {
            return .opds1
        }

        return .unknown
    }

    public static func detect(from data: Data) -> OPDSFormat {
        // Check first bytes for JSON vs XML
        guard let firstChar = String(data: data.prefix(1), encoding: .utf8) else {
            return .unknown
        }

        if firstChar == "{" || firstChar == "[" {
            return .opds2
        } else if firstChar == "<" {
            return .opds1
        }

        return .unknown
    }
}
