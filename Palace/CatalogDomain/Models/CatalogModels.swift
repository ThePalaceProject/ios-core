import Foundation

public struct CatalogFeed {
    public let title: String
    public let entries: [CatalogEntry]
    let opdsFeed: TPPOPDSFeed

    /// OPDS 2 feed data (nil when feed was parsed as OPDS 1)
    let opds2Feed: OPDS2Feed?

    /// True when this feed came from an OPDS 2 source
    var isOPDS2: Bool { opds2Feed != nil }

    // MARK: - OPDS 1 init (existing path)

    init?(feed: TPPOPDSFeed?) {
        guard let feed else { return nil }
        self.title = feed.title ?? "Catalog"
        self.opdsFeed = feed
        self.opds2Feed = nil
        let entries = (feed.entries as? [TPPOPDSEntry]) ?? []
        self.entries = entries.map { CatalogEntry(entry: $0) }
    }

    // MARK: - OPDS 2 init

    init(opds2Feed: OPDS2Feed) {
        self.title = opds2Feed.title
        self.opds2Feed = opds2Feed

        // Create a minimal empty TPPOPDSFeed for backward compat with code that reads .opdsFeed
        let escapedTitle = opds2Feed.title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        let shellXML = """
        <feed xmlns="http://www.w3.org/2005/Atom">
          <id>opds2-shell</id>
          <title>\(escapedTitle)</title>
          <updated>2000-01-01T00:00:00Z</updated>
        </feed>
        """
        if let xml = TPPXML.xml(withData: shellXML.data(using: .utf8)),
           let feed = TPPOPDSFeed(xml: xml) {
            self.opdsFeed = feed
        } else {
            // Fallback: parse with an absolute minimal feed
            let fallback = "<feed xmlns=\"http://www.w3.org/2005/Atom\"><id>x</id><title>Catalog</title><updated>2000-01-01T00:00:00Z</updated></feed>"
            self.opdsFeed = TPPOPDSFeed(xml: TPPXML.xml(withData: fallback.data(using: .utf8)))!
        }

        let allPubs = opds2Feed.groups?.flatMap { $0.publications ?? [] }
            ?? opds2Feed.publications
            ?? []
        self.entries = allPubs.map { CatalogEntry(opds2Publication: $0) }
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

    init(opds2Publication pub: OPDS2Publication) {
        self.id = pub.metadata.id
        self.title = pub.metadata.title
        self.authors = []
    }
}

/// Represents a format entry point (e.g. "All", "eBooks", "Audiobooks")
/// with optional search descriptor URL for searching within that format.
public struct SearchFormatEntry: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let groupsFeedURL: URL
    public let searchDescriptorURL: URL?
    public let isActive: Bool
}
