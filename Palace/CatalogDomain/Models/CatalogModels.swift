import Foundation

public struct CatalogFeed {
  public let title: String
  public let entries: [CatalogEntry]
  public let opdsFeed: TPPOPDSFeed

  init?(feed: TPPOPDSFeed?) {
    guard let feed else { return nil }
    self.title = feed.title ?? "Catalog"
    self.opdsFeed = feed
    let entries = (feed.entries as? [TPPOPDSEntry]) ?? []
    self.entries = entries.map { CatalogEntry(entry: $0) }
  }
}

public struct CatalogEntry: Identifiable {
  public let id: String
  public let title: String
  public let authors: [String]

  init(entry: TPPOPDSEntry) {
    self.id = entry.identifier
    self.title = entry.title
    self.authors = (entry.authorStrings as? [String]) ?? []
  }
}


