import Foundation
import Combine

@MainActor
final class CatalogViewModel: ObservableObject {
  // MARK: - State Machine

  @Published private(set) var state: CatalogState = .loading

  /// Monotonically increasing counter. The view uses .onChange(of:) to scroll
  /// to top — fires exactly once per increment, no reset needed.
  @Published private(set) var scrollGeneration: UInt = 0

  // MARK: - Dependencies

  private let repository: CatalogRepositoryProtocol
  private let topLevelURLProvider: () -> URL?
  private let bookRegistry: TPPBookRegistry

  // MARK: - Public accessors for search
  var searchRepository: CatalogRepositoryProtocol { repository }
  var searchBaseURL: () -> URL? { topLevelURLProvider }

  // MARK: - Internal State
  private var lastLoadedURL: URL?
  private var currentLoadTask: Task<Void, Never>?

  init(
    repository: CatalogRepositoryProtocol,
    topLevelURLProvider: @escaping () -> URL?,
    bookRegistry: TPPBookRegistry = .shared
  ) {
    self.repository = repository
    self.topLevelURLProvider = topLevelURLProvider
    self.bookRegistry = bookRegistry
  }

  // MARK: - Public API

  func load() async {
    guard let url = topLevelURLProvider() else { return }

    // Skip if already loaded for this URL
    if case .loaded = state, url == lastLoadedURL { return }

    state = .loading
    currentLoadTask?.cancel()

    currentLoadTask = Task { [weak self] in
      guard let self, !Task.isCancelled else { return }

      do {
        let t0 = CFAbsoluteTimeGetCurrent()

        guard let feed = try await self.repository.loadTopLevelCatalog(at: url) else {
          guard !Task.isCancelled else { return }
          self.state = .error("Failed to load catalog")
          return
        }

        let t1 = CFAbsoluteTimeGetCurrent()
        guard !Task.isCancelled else { return }

        let mapped = await Task.detached(priority: .userInitiated) { () -> MappedCatalog in
          return await Self.mapFeed(feed)
        }.value

        let t2 = CFAbsoluteTimeGetCurrent()
        guard !Task.isCancelled else { return }

        // Warm first lane's image cache with correct display-height keys pre-render
        let laneDisplayHeight = 150
        let firstLaneBooks = mapped.lanes.first?.books.prefix(7) ?? []
        let warmKeys = firstLaneBooks.flatMap {
          ["\($0.identifier)_\(laneDisplayHeight)pt", $0.identifier]
        }
        if !warmKeys.isEmpty {
          await ImageCache.shared.warmMemoryCache(for: Array(warmKeys))
        }

        guard !Task.isCancelled else { return }

        let content = mapped.toCatalogContent()
        self.state = .loaded(content)
        self.lastLoadedURL = url

        let t3 = CFAbsoluteTimeGetCurrent()
        let lanesCount = mapped.lanes.count
        let booksCount = mapped.lanes.reduce(0) { $0 + $1.books.count }
        Log.info(#file, "[PERF] Catalog load: fetch=\(Int((t1-t0)*1000))ms, map=\(Int((t2-t1)*1000))ms, render=\(Int((t3-t2)*1000))ms, total=\(Int((t3-t0)*1000))ms (\(lanesCount) lanes, \(booksCount) books)")

        // Warm remaining visible lanes in background post-render
        let remainingBooks = mapped.lanes.dropFirst().prefix(2).flatMap { $0.books }.prefix(20)
        if !remainingBooks.isEmpty {
          let bgKeys = remainingBooks.flatMap {
            ["\($0.identifier)_\(laneDisplayHeight)pt", $0.identifier]
          }
          Task { await ImageCache.shared.warmMemoryCache(for: Array(bgKeys)) }
        }

        // Prefetch thumbnails for visible lanes (network fetch for uncached)
        if !mapped.lanes.isEmpty {
          let visibleBooks = mapped.lanes.prefix(3).flatMap { $0.books }
          await self.prefetchThumbnails(for: Array(visibleBooks.prefix(30)))
        } else if !mapped.ungroupedBooks.isEmpty {
          await self.prefetchThumbnails(for: Array(mapped.ungroupedBooks.prefix(20)))
        }

        // Deferred prefetch for below-fold lanes
        if mapped.lanes.count > 3 {
          Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            let remaining = mapped.lanes.dropFirst(3).flatMap { $0.books }
            for batch in stride(from: 0, to: remaining.count, by: 20) {
              let end = min(batch + 20, remaining.count)
              await self.prefetchThumbnails(for: Array(remaining[batch..<end]))
            }
          }
        }

        // Preload inactive entry points in background
        let inactiveEntryPoints = mapped.entryPoints.filter { !$0.active }
        if !inactiveEntryPoints.isEmpty {
          Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
              for ep in inactiveEntryPoints {
                guard let epURL = ep.href else { continue }
                group.addTask {
                  do {
                    _ = try await self.repository.loadTopLevelCatalog(at: epURL)
                    Log.info(#file, "[PERF] Preloaded entry point '\(ep.title)'")
                  } catch { }
                }
              }
            }
          }
        }
      } catch is CancellationError {
        Log.debug(#file, "Catalog load was cancelled")
        return
      } catch {
        guard !Task.isCancelled else { return }
        Log.error(#file, "Failed to load catalog: \(error.localizedDescription)")
        self.state = .error(error.localizedDescription)
      }
    }
  }

  @MainActor
  func forceRefresh() async {
    Log.info(#file, "Force refreshing catalog...")
    repository.invalidateCache(for: topLevelURLProvider() ?? URL(fileURLWithPath: "/"))
    URLCache.shared.removeAllCachedResponses()
    lastLoadedURL = nil
    state = .loading
    await load()
  }

  func refresh() async {
    guard let url = topLevelURLProvider() else { return }
    (repository as? CatalogRepository)?.invalidateCache(for: url)
    lastLoadedURL = nil
    currentLoadTask?.cancel()
    state = .loading
    await load()
  }

  @MainActor
  func applyFacet(_ facet: CatalogFilter) async {
    guard let href = facet.href else { return }
    guard let currentContent = state.content else { return }

    let optimisticSelectors = currentContent.selectors.withSelectedFacet(facet)

    // Try synchronous cache check — instant swap, no opacity fade
    if let cachedFeed = repository.cachedFeed(for: href) {
      let mapped = Self.mapFeed(cachedFeed)
      let newContent = mapped.toCatalogContent()
      state = .loaded(CatalogContent(
        title: newContent.title,
        feed: newContent.feed,
        selectors: CatalogSelectors(
          entryPoints: newContent.selectors.entryPoints,
          facetGroups: optimisticSelectors.facetGroups
        )
      ))
      scrollGeneration &+= 1
      return
    }

    // Cache miss — show current content at 0.6 opacity while fetching
    let optimisticContent = CatalogContent(
      title: currentContent.title,
      feed: currentContent.feed,
      selectors: optimisticSelectors
    )
    state = .applyingFacet(optimisticContent)

    do {
      if let feed = try await repository.loadTopLevelCatalog(at: href) {
        let mapped = Self.mapFeed(feed)
        state = .loaded(mapped.toCatalogContent())
        scrollGeneration &+= 1
      } else {
        state = .loaded(currentContent)
      }
    } catch {
      state = .loaded(CatalogContent(
        title: currentContent.title,
        feed: currentContent.feed,
        selectors: currentContent.selectors,
        transientError: error.localizedDescription
      ))
    }
  }

  @MainActor
  func applyEntryPoint(_ facet: CatalogFilter) async {
    guard let href = facet.href else { return }
    guard let currentContent = state.content else { return }

    let previousContent = currentContent
    currentLoadTask?.cancel()

    // Optimistically update entry point selection
    let optimisticSelectors = currentContent.selectors.withSelectedEntryPoint(facet)

    // Try synchronous cache check — instant swap, no skeleton
    if let cachedFeed = repository.cachedFeed(for: href) {
      let mapped = Self.mapFeed(cachedFeed)
      let newContent = mapped.toCatalogContent()
      state = .loaded(CatalogContent(
        title: newContent.title,
        feed: newContent.feed,
        selectors: CatalogSelectors(
          entryPoints: optimisticSelectors.entryPoints,
          facetGroups: newContent.selectors.facetGroups
        )
      ))
      lastLoadedURL = href
      scrollGeneration &+= 1
      return
    }

    // Cache miss — show skeleton with tabs visible
    state = .switchingEntryPoint(optimisticSelectors)

    do {
      if let feed = try await repository.loadTopLevelCatalog(at: href) {
        let mapped = Self.mapFeed(feed)
        let newContent = mapped.toCatalogContent()
        state = .loaded(CatalogContent(
          title: newContent.title,
          feed: newContent.feed,
          selectors: CatalogSelectors(
            entryPoints: optimisticSelectors.entryPoints,
            facetGroups: newContent.selectors.facetGroups
          )
        ))
        lastLoadedURL = href
        scrollGeneration &+= 1
      } else {
        state = .loaded(previousContent)
      }
    } catch {
      state = .loaded(CatalogContent(
        title: previousContent.title,
        feed: previousContent.feed,
        selectors: previousContent.selectors,
        transientError: error.localizedDescription
      ))
    }
  }

  func handleAccountChange() async {
    guard let url = topLevelURLProvider() else { return }
    if lastLoadedURL == nil || url != lastLoadedURL {
      currentLoadTask?.cancel()
      state = .loading
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

// MARK: - Feed Mapping

extension CatalogViewModel {
  struct MappedCatalog {
    let title: String
    let entries: [CatalogEntry]
    let lanes: [CatalogLaneModel]
    let ungroupedBooks: [TPPBook]
    let facetGroups: [CatalogFilterGroup]
    let entryPoints: [CatalogFilter]
  }

  static func mapFeed(_ feed: CatalogFeed) -> MappedCatalog {
    if let opds2 = feed.opds2Feed {
      return mapOPDS2Feed(opds2, title: feed.title, entries: feed.entries)
    }

    let title = feed.title
    let entries = feed.entries
    let feedObjc = feed.opdsFeed

    switch feedObjc.type {
    case .acquisitionGrouped:
      let (facetGroups, entryPoints) = extractFacets(from: feedObjc)
      let (lanes, _) = buildGroupedContent(from: feedObjc)
      return MappedCatalog(
        title: title, entries: entries, lanes: lanes, ungroupedBooks: [],
        facetGroups: facetGroups.isEmpty ? [] : facetGroups, entryPoints: entryPoints
      )
    case .acquisitionUngrouped:
      let ungroupedBooks = (feedObjc.entries as? [TPPOPDSEntry])?.compactMap { makeBook(from: $0) } ?? []
      let (facetGroups, entryPoints) = extractFacets(from: feedObjc)
      return MappedCatalog(
        title: title, entries: entries, lanes: [], ungroupedBooks: ungroupedBooks,
        facetGroups: facetGroups, entryPoints: entryPoints
      )
    case .navigation, .invalid:
      return MappedCatalog(title: title, entries: entries, lanes: [], ungroupedBooks: [], facetGroups: [], entryPoints: [])
    @unknown default:
      return MappedCatalog(title: title, entries: entries, lanes: [], ungroupedBooks: [], facetGroups: [], entryPoints: [])
    }
  }

  private static func mapOPDS2Feed(_ feed: OPDS2Feed, title: String, entries: [CatalogEntry]) -> MappedCatalog {
    Log.info(#file, "[OPDS2-DIAG] Mapping OPDS2 feed: \"\(feed.title)\", grouped=\(feed.isGroupedFeed), publications=\(feed.isPublicationFeed), navigation=\(feed.isNavigationFeed)")

    if feed.isGroupedFeed {
      let lanes = buildOPDS2GroupedContent(from: feed)
      let (facetGroups, entryPoints) = extractOPDS2Facets(from: feed)
      return MappedCatalog(title: title, entries: entries, lanes: lanes, ungroupedBooks: [], facetGroups: facetGroups, entryPoints: entryPoints)
    } else if feed.isPublicationFeed {
      let books = feed.publications?.compactMap { $0.toBook() } ?? []
      Log.info(#file, "[OPDS2-DIAG] Mapped \(books.count) books from publication feed")
      let (facetGroups, entryPoints) = extractOPDS2Facets(from: feed)
      return MappedCatalog(title: title, entries: entries, lanes: [], ungroupedBooks: books, facetGroups: facetGroups, entryPoints: entryPoints)
    } else {
      return MappedCatalog(title: title, entries: entries, lanes: [], ungroupedBooks: [], facetGroups: [], entryPoints: [])
    }
  }

  private static func buildOPDS2GroupedContent(from feed: OPDS2Feed) -> [CatalogLaneModel] {
    guard let groups = feed.groups else { return [] }
    var lanes: [CatalogLaneModel] = []
    for group in groups {
      let books = (group.publications ?? []).compactMap { $0.toBook() }
      guard !books.isEmpty else { continue }
      lanes.append(CatalogLaneModel(title: group.title, books: books, moreURL: group.moreURL, isLoading: books.count < 3))
    }
    Log.info(#file, "[OPDS2-DIAG] Built \(lanes.count) lanes from OPDS2 groups, total books=\(lanes.reduce(0) { $0 + $1.books.count })")
    return lanes
  }

  static func extractOPDS2Facets(from feed: OPDS2Feed) -> ([CatalogFilterGroup], [CatalogFilter]) {
    var entryPoints: [CatalogFilter] = []
    if let links = feed.links {
      for link in links {
        if let href = link.hrefURL,
           (link.href.contains("entrypoint=") || link.rel == "http://opds-spec.org/facet"),
           let title = link.title, !title.isEmpty {
          let isActive = link.properties?.numberOfItems != nil
          entryPoints.append(CatalogFilter(id: link.href, title: title, href: href, active: isActive))
        }
      }
    }
    guard let feedFacets = feed.facets else { return ([], entryPoints) }
    let entryPointGroupNames: Set<String> = ["formats", "entrypoint", "entry point", "entry points"]
    var groups: [CatalogFilterGroup] = []
    for facetGroup in feedFacets {
      let filters = facetGroup.links.compactMap { link -> CatalogFilter? in
        guard let url = link.hrefURL else { return nil }
        return CatalogFilter(id: link.href, title: link.title, href: url, active: link.isActive)
      }
      guard !filters.isEmpty else { continue }
      if entryPointGroupNames.contains(facetGroup.title.lowercased()) {
        entryPoints = filters
      } else {
        groups.append(CatalogFilterGroup(id: facetGroup.title, name: facetGroup.title, filters: filters))
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
        if let group = entry.groupAttributes, let book = makeBook(from: entry) {
          let title = group.title ?? ""
          if titleToBooks[title] == nil { orderedTitles.append(title) }
          titleToBooks[title, default: []].append(book)
          if titleToMoreURL[title] == nil { titleToMoreURL[title] = group.href }
        }
      }
    }
    return (orderedTitles.map { title in
      CatalogLaneModel(title: title, books: titleToBooks[title] ?? [], moreURL: titleToMoreURL[title] ?? nil, isLoading: (titleToBooks[title] ?? []).count < 3)
    }, [])
  }

  static func extractFacets(from feed: TPPOPDSFeed) -> ([CatalogFilterGroup], [CatalogFilter]) {
    var groupNames: [String] = []
    var groupToFacets: [String: [CatalogFilter]] = [:]
    var entryPoints: [CatalogFilter] = []
    for case let link as TPPOPDSLink in feed.links {
      guard link.rel == TPPOPDSRelationFacet else { continue }
      var isEntryPoint = false
      var groupName: String?
      for (key, value) in link.attributes {
        if let keyStr = key as? String, TPPOPDSAttributeKeyStringIsFacetGroupType(keyStr) { isEntryPoint = true }
        else if let keyStr = key as? String, TPPOPDSAttributeKeyStringIsFacetGroup(keyStr) { groupName = (value as? String) ?? String(describing: value) }
      }
      let isActive: Bool = link.attributes.contains { (k, v) in
        guard let keyStr = k as? String, TPPOPDSAttributeKeyStringIsActiveFacet(keyStr) else { return false }
        if let s = v as? String { return s.localizedCaseInsensitiveContains("true") }
        return false
      }
      let facet = CatalogFilter(id: UUID().uuidString, title: link.title ?? "", href: link.href, active: isActive)
      if isEntryPoint { entryPoints.append(facet) }
      else if let groupName = groupName {
        if !groupNames.contains(groupName) { groupNames.append(groupName) }
        groupToFacets[groupName, default: []].append(facet)
      }
    }
    return (groupNames.map { CatalogFilterGroup(id: $0, name: $0, filters: groupToFacets[$0] ?? []) }, entryPoints)
  }

  private func prefetchThumbnails(for books: [TPPBook]) {
    let set = Set(books)
    bookRegistry.thumbnailImages(forBooks: set) { _ in }
  }

  static func makeBook(from entry: TPPOPDSEntry, bookRegistry: TPPBookRegistry = .shared) -> TPPBook? {
    guard var book = TPPBook(entry: entry) else { return nil }
    if let updated = bookRegistry.updatedBookMetadata(book) { book = updated }
    if book.defaultBookContentType == .unsupported { return nil }
    if book.defaultAcquisition == nil { return nil }
    return book
  }
}
