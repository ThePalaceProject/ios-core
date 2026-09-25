import Foundation

// Shape of TPPProblemDocument.DetailLoanTermLimitReached: a legitimate
// snake_case string constant in a .convertFromSnakeCase file. Not an enum case.
struct Doc: Codable {
    static let detailLoanTermLimitReached = "loan_term_limit_reached"
    private static let showTitleKey = "show_title"
    let detail: String?
    static func parse(_ data: Data) throws -> Doc {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Doc.self, from: data)
    }
}
