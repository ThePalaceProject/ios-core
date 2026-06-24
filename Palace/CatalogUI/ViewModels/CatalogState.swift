import Foundation
import PalaceCatalog

// MARK: - Catalog State Machine

/// Single source of truth for the catalog screen.
/// Every case carries exactly the data the view needs to render.
/// Impossible states (e.g., loading + error, lanes + ungrouped) are unrepresentable.
enum CatalogState {
  /// Initial load or refresh — no content exists yet.
  case loading

  /// Content is available and idle.
  case loaded(CatalogContent)

  /// A facet was tapped. Previous content stays visible at 0.6 opacity
  /// while the network call completes.
  case applyingFacet(CatalogContent)

  /// An entry point tab was tapped (cache miss). Content is cleared and a
  /// skeleton is shown while the network call completes. The selector tabs
  /// remain visible above the skeleton.
  case switchingEntryPoint(CatalogSelectors)

  /// Unrecoverable error during initial load (no content to fall back to).
  case error(String)

  /// The initial load failed because the device has no connectivity. Distinct
  /// from `.error` so the view can direct the patron to their downloaded books
  /// instead of offering a Reload that cannot succeed offline. Reload happens
  /// automatically when connectivity returns (see `CatalogViewModel`).
  case offline
}

// MARK: - Computed Helpers

extension CatalogState {
  var isApplyingFacet: Bool {
    if case .applyingFacet = self { return true }
    return false
  }

  /// Extract content if in a loaded or applying-facet state.
  var content: CatalogContent? {
    switch self {
    case .loaded(let c), .applyingFacet(let c): return c
    default: return nil
    }
  }

  /// Extract title for navigation bar, if available.
  var title: String? {
    content?.title
  }

  /// All books across all lanes/ungrouped, for search.
  var allBooks: [TPPBook] {
    guard let content else { return [] }
    switch content.feed {
    case .grouped(let lanes): return lanes.flatMap(\.books)
    case .ungrouped(let books): return books
    case .empty: return []
    }
  }
}

// MARK: - Content Value Types

/// All displayable catalog data. Value type — cheap to copy for rollback.
struct CatalogContent {
  let title: String
  let feed: CatalogFeedContent
  let selectors: CatalogSelectors
  /// Non-nil when a recoverable error occurred (e.g., facet apply failed).
  let transientError: String?

  init(title: String, feed: CatalogFeedContent, selectors: CatalogSelectors, transientError: String? = nil) {
    self.title = title
    self.feed = feed
    self.selectors = selectors
    self.transientError = transientError
  }
}

/// Mutually exclusive feed shape — grouped lanes OR ungrouped book list.
/// Enforces the invariant at the type level.
enum CatalogFeedContent {
  case grouped([CatalogLaneModel])
  case ungrouped([TPPBook])
  case empty
}

/// Entry points + facet groups, always travel together.
struct CatalogSelectors {
  let entryPoints: [CatalogFilter]
  let facetGroups: [CatalogFilterGroup]

  static let empty = CatalogSelectors(entryPoints: [], facetGroups: [])
}

// MARK: - Selector Transforms

extension CatalogSelectors {
  /// Return a copy with the given facet marked active within its group.
  func withSelectedFacet(_ selected: CatalogFilter) -> CatalogSelectors {
    let updated = facetGroups.map { group in
      CatalogFilterGroup(
        id: group.id,
        name: group.name,
        filters: group.filters.map { f in
          CatalogFilter(id: f.id, title: f.title, href: f.href, active: f.id == selected.id)
        }
      )
    }
    return CatalogSelectors(entryPoints: entryPoints, facetGroups: updated)
  }

  /// Return a copy with the given entry point marked active.
  func withSelectedEntryPoint(_ selected: CatalogFilter) -> CatalogSelectors {
    let updated = entryPoints.map { ep in
      CatalogFilter(id: ep.id, title: ep.title, href: ep.href, active: ep.id == selected.id)
    }
    return CatalogSelectors(entryPoints: updated, facetGroups: facetGroups)
  }
}

// MARK: - MappedCatalog Bridge

extension CatalogViewModel.MappedCatalog {
  func toCatalogContent() -> CatalogContent {
    let feed: CatalogFeedContent
    if !lanes.isEmpty {
      feed = .grouped(lanes)
    } else if !ungroupedBooks.isEmpty {
      feed = .ungrouped(ungroupedBooks)
    } else {
      feed = .empty
    }

    return CatalogContent(
      title: title,
      feed: feed,
      selectors: CatalogSelectors(
        entryPoints: entryPoints,
        facetGroups: facetGroups
      )
    )
  }
}
