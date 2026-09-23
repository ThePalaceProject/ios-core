import Foundation

public final class TPPBookAuthor: NSObject {

    public let name: String
    public let relatedBooksURL: URL?

    public init(authorName: String, relatedBooksURL: URL?) {
        self.name = authorName
        self.relatedBooksURL = relatedBooksURL
    }
}
