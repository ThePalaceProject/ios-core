import Foundation

// MARK: - CatalogFeed

public struct CatalogFeed {
  public let title: String
  public let entries: [CatalogEntry]
  public let opdsFeed: TPPOPDSFeed

  init?(feed: TPPOPDSFeed?) {
    guard let feed else {
      return nil
    }
    title = feed.title ?? "Catalog"
    opdsFeed = feed
    let entries = (feed.entries as? [TPPOPDSEntry]) ?? []
    self.entries = entries.map { CatalogEntry(entry: $0) }
  }
}

// MARK: - CatalogEntry

public struct CatalogEntry: Identifiable {
  public let id: String
  public let title: String
  public let authors: [String]

  init(entry: TPPOPDSEntry) {
    id = entry.identifier
    title = entry.title
    authors = (entry.authorStrings as? [String]) ?? []
  }
}
