import Foundation

@objcMembers final class TPPBookAuthor: NSObject {

  let name: String
  let relatedBooksURL: URL?

  init(authorName: String, relatedBooksURL: URL?) {
    self.name = authorName
    self.relatedBooksURL = relatedBooksURL
  }
}
