import Foundation

struct CatalogFilter: Identifiable, Hashable {
    let id: String
    let title: String
    let href: URL?
    let active: Bool
}

struct CatalogFilterGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let filters: [CatalogFilter]
}

/// A format entry point shown in the search screen filter row.
/// Extracted from the groups feed's entry-point facets (e.g. All, eBooks, Audiobooks).
public struct SearchFormatEntry: Identifiable, Hashable {
    public let id: String
    public let title: String

    /// Groups feed URL for this format (e.g. /groups/?entrypoint=Book).
    /// Used to lazily fetch the format-specific search descriptor URL.
    public let groupsFeedURL: URL

    /// OpenSearch descriptor URL for this format.
    /// Populated immediately for the active format; nil for others until first use.
    public let searchDescriptorURL: URL?

    public let isActive: Bool
}
