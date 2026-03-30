import Foundation
import Combine

@MainActor
final class CatalogViewModel: ObservableObject {
  @Published private(set) var title: String = ""
  @Published private(set) var entries: [CatalogEntry] = []
  @Published private(set) var lanes: [CatalogLaneModel] = []
  @Published private(set) var ungroupedBooks: [TPPBook] = []
  @Published private(set) var isLoading: Bool = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var facetGroups: [CatalogFilterGroup] = []
  @Published private(set) var entryPoints: [CatalogFilter] = []
  @Published var isContentReloading: Bool = false
  @Published private(set) var isOptimisticLoading: Bool = false
  @Published var shouldScrollToTop: Bool = false

  private let repository: CatalogRepositoryProtocol
  private let topLevelURLProvider: () -> URL?
  
  private var previousLanes: [CatalogLaneModel] = []
  private var previousUngroupedBooks: [TPPBook] = []
  private var previousFacetGroups: [CatalogFilterGroup] = []
  private var previousEntryPoints: [CatalogFilter] = []
  
  // MARK: - Public accessors for search
  var searchRepository: CatalogRepositoryProtocol { repository }
  var searchBaseURL: () -> URL? { topLevelURLProvider }
  private var lastLoadedURL: URL?
  private var currentLoadTask: Task<Void, Never>? = nil

  init(repository: CatalogRepositoryProtocol, topLevelURLProvider: @escaping () -> URL?) {
    self.repository = repository
    self.topLevelURLProvider = topLevelURLProvider
  }

  // MARK: - Public API

  func load() async {
    guard let url = topLevelURLProvider() else { 
      await MainActor.run { self.isLoading = false }
      return 
    }
    
    if (!lanes.isEmpty || !ungroupedBooks.isEmpty), url == lastLoadedURL { 
      await MainActor.run { self.isLoading = false }
      return 
    }
    
    await MainActor.run {
      self.isLoading = true
      self.errorMessage = nil
    }

    currentLoadTask?.cancel()
    
    currentLoadTask = Task { [weak self] in
      guard let self, !Task.isCancelled else { return }
      
      do {
        guard let feed = try await self.repository.loadTopLevelCatalog(at: url) else {
          guard !Task.isCancelled else { return }
          await MainActor.run { 
            if !Task.isCancelled {
              self.errorMessage = "Failed to load catalog"
              self.isLoading = false
            }
          }
          return
        }

        guard !Task.isCancelled else { return }
        
        let mapped = await Task.detached(priority: .userInitiated) { () -> MappedCatalog in
          return await Self.mapFeed(feed)
        }.value

        guard !Task.isCancelled else { return }
        
        await MainActor.run {
          guard !Task.isCancelled else { return }
          self.title = mapped.title
          self.entries = mapped.entries
          self.lanes = mapped.lanes
          self.ungroupedBooks = mapped.ungroupedBooks
          self.facetGroups = mapped.facetGroups
          self.entryPoints = mapped.entryPoints
          self.lastLoadedURL = url
          self.isLoading = false
        }

        guard !Task.isCancelled else { return }
        if !mapped.lanes.isEmpty {
          let visibleBooks = mapped.lanes.prefix(3).flatMap { $0.books }
          await self.prefetchThumbnails(for: Array(visibleBooks.prefix(30)))
        } else if !mapped.ungroupedBooks.isEmpty {
          await self.prefetchThumbnails(for: Array(mapped.ungroupedBooks.prefix(20)))
        }
      } catch is CancellationError {
        // Task was cancelled (e.g., view disappeared during rotation) - don't show error
        Log.debug(#file, "Catalog load was cancelled")
        return
      } catch {
        guard !Task.isCancelled else { return }
        Log.error(#file, "Failed to load catalog: \(error.localizedDescription)")
        await MainActor.run { 
          if !Task.isCancelled {
            self.errorMessage = error.localizedDescription
            self.isLoading = false
          }
        }
      }
    }
  }
  
  @MainActor
  func forceRefresh() async {
    Log.info(#file, "Force refreshing catalog...")
    
    repository.invalidateCache(for: topLevelURLProvider() ?? URL(string: "about:blank")!)
    URLCache.shared.removeAllCachedResponses()
    
    lastLoadedURL = nil
    lanes.removeAll()
    ungroupedBooks.removeAll()
    errorMessage = nil
    
    await load()
  }

  func refresh() async {
    guard let url = topLevelURLProvider() else { return }
    (repository as? CatalogRepository)?.invalidateCache(for: url)
    lanes.removeAll()
    ungroupedBooks.removeAll()
    entryPoints.removeAll()
    currentLoadTask?.cancel()
    await load()
  }

  @MainActor
  func applyFacet(_ facet: CatalogFilter) async {
    guard let href = facet.href else { return }
    
    storePreviousState()
    
    isOptimisticLoading = true
    errorMessage = nil
    
    updateFacetGroupsOptimistically(selectedFacet: facet)
    
    do {
      if let feed = try await repository.loadTopLevelCatalog(at: href) {
        let mapped = Self.mapFeed(feed)
        self.lanes = mapped.lanes
        self.ungroupedBooks = mapped.ungroupedBooks
        self.facetGroups = mapped.facetGroups
        self.entryPoints = mapped.entryPoints
      }
      isOptimisticLoading = false

      triggerScrollToTop()
    } catch {
      restorePreviousState()
      errorMessage = error.localizedDescription
      isOptimisticLoading = false
    }
  }

  /// Applies an entry point (e.g., Ebooks/Audiobooks) with optimistic loading.
  @MainActor
  func applyEntryPoint(_ facet: CatalogFilter) async {
    guard let href = facet.href else { return }

    storePreviousState()

    isContentReloading = true
    isOptimisticLoading = true
    errorMessage = nil

    updateEntryPointsOptimistically(selectedEntryPoint: facet)

    lanes.removeAll()
    ungroupedBooks.removeAll()
    currentLoadTask?.cancel()

    do {
      if let feed = try await repository.loadTopLevelCatalog(at: href) {
        let mapped = Self.mapFeed(feed)
        self.lanes = mapped.lanes
        self.ungroupedBooks = mapped.ungroupedBooks
        self.facetGroups = mapped.facetGroups
        self.entryPoints = mapped.entryPoints
      }
      isOptimisticLoading = false

      triggerScrollToTop()
    } catch {
      restorePreviousState()
      errorMessage = error.localizedDescription
      isOptimisticLoading = false
    }
    isContentReloading = false
  }

  func handleAccountChange() async {
    guard let url = topLevelURLProvider() else { return }

    if lastLoadedURL == nil || url != lastLoadedURL {
      await MainActor.run {
        self.isLoading = true
        self.errorMessage = nil
        self.lanes.removeAll()
        self.ungroupedBooks.removeAll()
      }
      currentLoadTask?.cancel()
      await refresh()
    }
  }
}

// MARK: - Models

struct CatalogLaneModel: Identifiable {
  let id = UUID()
  let title: String
  let books: [TPPBook]
  let moreURL: URL?
  let isLoading: Bool
  
  init(title: String, books: [TPPBook], moreURL: URL?, isLoading: Bool = false) {
    self.title = title
    self.books = books
    self.moreURL = moreURL
    self.isLoading = isLoading
  }
}

// MARK: - Helpers

extension CatalogViewModel {
  /// Result of mapping an OPDS feed to view model data
  struct MappedCatalog {
    let title: String
    let entries: [CatalogEntry]
    let lanes: [CatalogLaneModel]
    let ungroupedBooks: [TPPBook]
    let facetGroups: [CatalogFilterGroup]
    let entryPoints: [CatalogFilter]
  }

  /// Produce a MappedCatalog from a CatalogFeed
  static func mapFeed(_ feed: CatalogFeed) -> MappedCatalog {
    // OPDS 2 path
    if let opds2 = feed.opds2Feed {
      return mapOPDS2Feed(opds2, title: feed.title, entries: feed.entries)
    }

    // OPDS 1 path (existing)
    let title = feed.title
    let entries = feed.entries
    let feedObjc = feed.opdsFeed

    switch feedObjc.type {
    case .acquisitionGrouped:
      let (facetGroups, entryPoints) = extractFacets(from: feedObjc)
      let (lanes, _) = buildGroupedContent(from: feedObjc)
      return MappedCatalog(
        title: title,
        entries: entries,
        lanes: lanes,
        ungroupedBooks: [],
        facetGroups: facetGroups.isEmpty ? [] : facetGroups,
        entryPoints: entryPoints
      )
    case .acquisitionUngrouped:
      let ungroupedBooks = (feedObjc.entries as? [TPPOPDSEntry])?.compactMap { makeBook(from: $0) } ?? []
      let (facetGroups, entryPoints) = extractFacets(from: feedObjc)
      return MappedCatalog(
        title: title,
        entries: entries,
        lanes: [],
        ungroupedBooks: ungroupedBooks,
        facetGroups: facetGroups,
        entryPoints: entryPoints
      )
    case .navigation, .invalid:
      return MappedCatalog(
        title: title,
        entries: entries,
        lanes: [],
        ungroupedBooks: [],
        facetGroups: [],
        entryPoints: []
      )
    @unknown default:
      return MappedCatalog(
        title: title,
        entries: entries,
        lanes: [],
        ungroupedBooks: [],
        facetGroups: [],
        entryPoints: []
      )
    }
  }

  // MARK: - OPDS 2 Mapping

  /// Map an OPDS 2 feed to a MappedCatalog
  private static func mapOPDS2Feed(_ feed: OPDS2Feed, title: String, entries: [CatalogEntry]) -> MappedCatalog {
    Log.info(#file, "[OPDS2-DIAG] Mapping OPDS2 feed: \"\(feed.title)\", " +
      "grouped=\(feed.isGroupedFeed), " +
      "publications=\(feed.isPublicationFeed), " +
      "navigation=\(feed.isNavigationFeed)")

    if feed.isGroupedFeed {
      let lanes = buildOPDS2GroupedContent(from: feed)
      let (facetGroups, entryPoints) = extractOPDS2Facets(from: feed)
      return MappedCatalog(
        title: title,
        entries: entries,
        lanes: lanes,
        ungroupedBooks: [],
        facetGroups: facetGroups,
        entryPoints: entryPoints
      )
    } else if feed.isPublicationFeed {
      let books = feed.publications?.compactMap { $0.toBook() } ?? []
      Log.info(#file, "[OPDS2-DIAG] Mapped \(books.count) books from publication feed")
      let (facetGroups, entryPoints) = extractOPDS2Facets(from: feed)
      return MappedCatalog(
        title: title,
        entries: entries,
        lanes: [],
        ungroupedBooks: books,
        facetGroups: facetGroups,
        entryPoints: entryPoints
      )
    } else {
      return MappedCatalog(
        title: title,
        entries: entries,
        lanes: [],
        ungroupedBooks: [],
        facetGroups: [],
        entryPoints: []
      )
    }
  }

  /// Build lane models from OPDS 2 grouped feed
  private static func buildOPDS2GroupedContent(from feed: OPDS2Feed) -> [CatalogLaneModel] {
    guard let groups = feed.groups else { return [] }

    var lanes: [CatalogLaneModel] = []
    for group in groups {
      let books = (group.publications ?? []).compactMap { $0.toBook() }
      guard !books.isEmpty else { continue }

      let lane = CatalogLaneModel(
        title: group.title,
        books: books,
        moreURL: group.moreURL,
        isLoading: books.count < 3
      )
      lanes.append(lane)
    }

    Log.info(#file, "[OPDS2-DIAG] Built \(lanes.count) lanes from OPDS2 groups, " +
      "total books=\(lanes.reduce(0) { $0 + $1.books.count })")

    return lanes
  }

  /// Extract facets from OPDS 2 feed
  static func extractOPDS2Facets(from feed: OPDS2Feed) -> ([CatalogFilterGroup], [CatalogFilter]) {
    // Entry points come as top-level links with "entrypoint" in the href
    var entryPoints: [CatalogFilter] = []
    if let links = feed.links {
      for link in links {
        if let href = link.hrefURL,
           (link.href.contains("entrypoint=") || link.rel == "http://opds-spec.org/facet"),
           let title = link.title, !title.isEmpty {
          let isActive = link.properties?.numberOfItems != nil
          entryPoints.append(CatalogFilter(
            id: link.href,
            title: title,
            href: href,
            active: isActive
          ))
        }
      }
    }

    guard let feedFacets = feed.facets else { return ([], entryPoints) }

    // Entry point facet group names used by the Palace CM
    let entryPointGroupNames: Set<String> = ["formats", "entrypoint", "entry point", "entry points"]

    var groups: [CatalogFilterGroup] = []
    for facetGroup in feedFacets {
      let filters = facetGroup.links.compactMap { link -> CatalogFilter? in
        guard let url = link.hrefURL else { return nil }
        return CatalogFilter(
          id: link.href,
          title: link.title,
          href: url,
          active: link.isActive
        )
      }
      guard !filters.isEmpty else { continue }

      // Check if this facet group represents entry points (format selector)
      if entryPointGroupNames.contains(facetGroup.title.lowercased()) {
        entryPoints = filters
      } else {
        groups.append(CatalogFilterGroup(
          id: facetGroup.title,
          name: facetGroup.title,
          filters: filters
        ))
      }
    }

    return (groups, entryPoints)
  }

  private static func buildGroupedContent(from feed: TPPOPDSFeed) -> ([CatalogLaneModel], [TPPBook]) {
    var titleToBooks: [String: [TPPBook]] = [:]
    var titleToMoreURL: [String: URL?] = [:]
    var orderedTitles: [String] = []
    if let entries = feed.entries as? [TPPOPDSEntry] {
      for entry in entries {
        if let group = entry.groupAttributes,
           let book = makeBook(from: entry) {
          let title = group.title ?? ""
          if titleToBooks[title] == nil { orderedTitles.append(title) }
          titleToBooks[title, default: []].append(book)
          if titleToMoreURL[title] == nil { titleToMoreURL[title] = group.href }
        }
      }
    }
    let lanes: [CatalogLaneModel] = orderedTitles.map { title in
      let books = titleToBooks[title] ?? []
      let isLoading = books.count < 3
      return CatalogLaneModel(
        title: title, 
        books: books, 
        moreURL: titleToMoreURL[title] ?? nil, 
        isLoading: isLoading
      )
    }
    return (lanes, [])
  }

  /// Extract facet groups and entry points directly from OPDS links without ObjC wrappers
  static func extractFacets(from feed: TPPOPDSFeed) -> ([CatalogFilterGroup], [CatalogFilter]) {
    var groupNames: [String] = []
    var groupToFacets: [String: [CatalogFilter]] = [:]
    var entryPoints: [CatalogFilter] = []

    for case let link as TPPOPDSLink in feed.links {
      guard link.rel == TPPOPDSRelationFacet else { continue }

      var isEntryPoint = false
      var groupName: String?
      for (key, value) in link.attributes {
        if let keyStr = key as? String, TPPOPDSAttributeKeyStringIsFacetGroupType(keyStr) {
          isEntryPoint = true
        } else if let keyStr = key as? String, TPPOPDSAttributeKeyStringIsFacetGroup(keyStr) {
          groupName = (value as? String) ?? String(describing: value)
        }
      }

      // Determine active flag from attributes
      let isActive: Bool = link.attributes.contains { (k, v) in
        guard let keyStr = k as? String, TPPOPDSAttributeKeyStringIsActiveFacet(keyStr) else { return false }
        if let s = v as? String { return s.localizedCaseInsensitiveContains("true") }
        return false
      }

      let facet = CatalogFilter(
        id: UUID().uuidString,
        title: link.title ?? "",
        href: link.href,
        active: isActive
      )

      if isEntryPoint {
        entryPoints.append(facet)
      } else if let groupName = groupName {
        if !groupNames.contains(groupName) { groupNames.append(groupName) }
        groupToFacets[groupName, default: []].append(facet)
      }
    }

    let groups: [CatalogFilterGroup] = groupNames.map { name in
      CatalogFilterGroup(id: name, name: name, filters: groupToFacets[name] ?? [])
    }

    return (groups, entryPoints)
  }

  private func prefetchThumbnails(for books: [TPPBook]) {
    let set = Set(books)
    TPPBookRegistry.shared.thumbnailImages(forBooks: set) { _ in }
  }

  static func makeBook(from entry: TPPOPDSEntry) -> TPPBook? {
    guard var book = TPPBook(entry: entry) else { return nil }

    if let updated = TPPBookRegistry.shared.updatedBookMetadata(book) {
      book = updated
    }

    if book.defaultBookContentType == .unsupported { return nil }
    if book.defaultAcquisition == nil { return nil }
    return book
  }
  
  // MARK: - Scroll Management
  
  func triggerScrollToTop() {
    shouldScrollToTop = false
    // Use Task to defer the property change to next runloop iteration
    Task { @MainActor in
      self.shouldScrollToTop = true
    }
  }
  
  func resetScrollTrigger() {
    shouldScrollToTop = false
  }
  
  // MARK: - Optimistic Loading Helpers
  
  private func storePreviousState() {
    previousLanes = lanes
    previousUngroupedBooks = ungroupedBooks
    previousFacetGroups = facetGroups
    previousEntryPoints = entryPoints
  }
  
  private func restorePreviousState() {
    lanes = previousLanes
    ungroupedBooks = previousUngroupedBooks
    facetGroups = previousFacetGroups
    entryPoints = previousEntryPoints
  }
  
  private func updateFacetGroupsOptimistically(selectedFacet: CatalogFilter) {
    var updatedGroups: [CatalogFilterGroup] = []
    
    for group in facetGroups {
      var updatedFilters: [CatalogFilter] = []
      
      for filter in group.filters {
        if filter.id == selectedFacet.id {
          let updatedFilter = CatalogFilter(
            id: filter.id,
            title: filter.title,
            href: filter.href,
            active: true
          )
          updatedFilters.append(updatedFilter)
        } else {
          let updatedFilter = CatalogFilter(
            id: filter.id,
            title: filter.title,
            href: filter.href,
            active: false
          )
          updatedFilters.append(updatedFilter)
        }
      }
      
      let updatedGroup = CatalogFilterGroup(
        id: group.id,
        name: group.name,
        filters: updatedFilters
      )
      updatedGroups.append(updatedGroup)
    }
    
    facetGroups = updatedGroups
  }
  
  private func updateEntryPointsOptimistically(selectedEntryPoint: CatalogFilter) {
    var updatedEntryPoints: [CatalogFilter] = []
    
    for entryPoint in entryPoints {
      if entryPoint.id == selectedEntryPoint.id {
        let updated = CatalogFilter(
          id: entryPoint.id,
          title: entryPoint.title,
          href: entryPoint.href,
          active: true
        )
        updatedEntryPoints.append(updated)
      } else {
        let updated = CatalogFilter(
          id: entryPoint.id,
          title: entryPoint.title,
          href: entryPoint.href,
          active: false
        )
        updatedEntryPoints.append(updated)
      }
    }
    
    entryPoints = updatedEntryPoints
  }

}


