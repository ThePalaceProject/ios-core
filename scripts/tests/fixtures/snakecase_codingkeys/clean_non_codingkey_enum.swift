import Foundation

// Shape of the real OPDS2LinkRel: a wire-constant enum living beside a
// .convertFromSnakeCase decoder. Its raw values are link relations, not keys.
enum LinkRel: String {
    case passwordReset = "password_reset"
    case termsOfService = "terms_of_service"
}

struct AuthDoc: Codable {
    let id: String?
    static func parse(_ data: Data) throws -> AuthDoc {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(AuthDoc.self, from: data)
    }
}
