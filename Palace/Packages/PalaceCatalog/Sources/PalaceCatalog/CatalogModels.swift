import Foundation

public struct CatalogFeed: Sendable {
    public let title: String
    public let entries: [CatalogEntry]
    public let opdsFeed: TPPOPDSFeed

    /// OPDS 2 feed data (nil when feed was parsed as OPDS 1)
    public let opds2Feed: OPDS2Feed?

    /// True when this feed came from an OPDS 2 source
    public var isOPDS2: Bool { opds2Feed != nil }

    // MARK: - OPDS 1 init (existing path)

    public init?(feed: TPPOPDSFeed?) {
        guard let feed else { return nil }
        self.title = feed.title ?? "Catalog"
        self.opdsFeed = feed
        self.opds2Feed = nil
        let entries = (feed.entries as? [TPPOPDSEntry]) ?? []
        self.entries = entries.map { CatalogEntry(entry: $0) }
    }

    // MARK: - OPDS 2 init

    public init(opds2Feed: OPDS2Feed) {
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
            guard let fallbackData = fallback.data(using: .utf8),
                  let fallbackXML = TPPXML.xml(withData: fallbackData),
                  let fallbackFeed = TPPOPDSFeed(xml: fallbackXML) else {
                fatalError("Failed to create OPDS feed from static Atom XML literal")
            }
            self.opdsFeed = fallbackFeed
        }

        let allPubs = opds2Feed.groups?.flatMap { $0.publications ?? [] }
            ?? opds2Feed.publications
            ?? []
        // Dedupe by publication id across groups while preserving group ordering
        // (keep the FIRST occurrence). A publication that appears in two groups
        // (e.g. "Featured" and "New Releases") used to surface twice in the
        // flattened entries list.
        var seenIDs = Set<String>()
        var deduped: [OPDS2Publication] = []
        deduped.reserveCapacity(allPubs.count)
        for pub in allPubs {
            if seenIDs.insert(pub.metadata.id).inserted {
                deduped.append(pub)
            }
        }
        self.entries = deduped.map { CatalogEntry(opds2Publication: $0) }
    }
}

public struct CatalogEntry: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let authors: [String]

    public init(entry: TPPOPDSEntry) {
        self.id = entry.identifier
        self.title = entry.title
        self.authors = (entry.authorStrings as? [String]) ?? []
    }

    public init(opds2Publication pub: OPDS2Publication) {
        self.id = pub.metadata.id
        self.title = pub.metadata.title
        self.authors = []
    }
}

/// A format entry point shown in the search screen filter row.
/// Extracted from the groups feed's entry-point facets (e.g. All, eBooks, Audiobooks).
public struct SearchFormatEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String

    /// Groups feed URL for this format (e.g. /groups/?entrypoint=Book).
    /// Used to lazily fetch the format-specific search descriptor URL.
    public let groupsFeedURL: URL

    /// OpenSearch descriptor URL for this format.
    /// Populated immediately for the active format; nil for others until first use.
    public let searchDescriptorURL: URL?

    public let isActive: Bool

    public init(id: String, title: String, groupsFeedURL: URL, searchDescriptorURL: URL?, isActive: Bool) {
        self.id = id
        self.title = title
        self.groupsFeedURL = groupsFeedURL
        self.searchDescriptorURL = searchDescriptorURL
        self.isActive = isActive
    }
}
