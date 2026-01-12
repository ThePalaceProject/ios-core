import Foundation
import SwiftUI
import Combine

/// ViewModel for CatalogLaneMoreView that manages catalog feed loading, filtering, and sorting
@MainActor
class CatalogLaneMoreViewModel: ObservableObject {
  
  // MARK: - Published Properties
  
  // Content State
  @Published var lanes: [CatalogLaneModel] = []
  @Published var ungroupedBooks: [TPPBook] = []
  @Published var isLoading = true
  @Published var error: String?
  
  @Published var nextPageURL: URL?
  @Published var isLoadingMore = false
  
  // UI State
  @Published var showingSortSheet = false
  @Published var showingFiltersSheet = false
  @Published var showSearch = false
  
  // Filter State
  @Published var facetGroups: [CatalogFilterGroup] = []
  @Published var pendingSelections: Set<String> = []
  @Published var appliedSelections: Set<String> = []
  @Published var isApplyingFilters = false
  
  // MARK: - Properties
  
  let title: String
  let url: URL
  private let filterService = CatalogFilterService.self
  private let api: DefaultCatalogAPI
  
  private var cancellables = Set<AnyCancellable>()
  
  // MARK: - Computed Properties
  
  var activeFiltersCount: Int {
    CatalogFilterService.activeFiltersCount(appliedSelections: appliedSelections)
  }
  
  var allBooks: [TPPBook] {
    if !lanes.isEmpty {
      return lanes.flatMap { $0.books }
    }
    return ungroupedBooks
  }
  
  var shouldShowPagination: Bool {
    return nextPageURL != nil
  }
  
  // MARK: - Initialization
  
  init(title: String, url: URL, api: DefaultCatalogAPI? = nil) {
    self.title = title
    self.url = url
    self.api = api ?? DefaultCatalogAPI(
      client: URLSessionNetworkClient(),
      parser: OPDSParser()
    )
    
    setupObservers()
  }
  
  private func setupObservers() {
    // Setup pending selections when filter sheet opens
    $showingFiltersSheet
      .filter { $0 } // Only when opening
      .sink { [weak self] _ in
        guard let self = self else { return }
        if !self.appliedSelections.isEmpty {
          self.pendingSelections = CatalogFilterService.reconstructSelectionsFromCurrentFacets(
            appliedSelections: self.appliedSelections,
            facetGroups: self.facetGroups
          )
        } else {
          self.pendingSelections = []
        }
      }
      .store(in: &cancellables)
  }
  
  // MARK: - Loading
  
  private var hasLoadedOnce = false
  
  func load(coordinator: NavigationCoordinator) async {
    if hasLoadedOnce, !facetGroups.isEmpty || !lanes.isEmpty || !ungroupedBooks.isEmpty {
      if let savedState = coordinator.resolveCatalogFilterState(for: url) {
        if appliedSelections != savedState.appliedSelections {
          restoreFilterState(savedState)
        }
      }
      return
    }
    
    isLoading = true
    error = nil
    defer { 
      isLoading = false
      hasLoadedOnce = true
    }
    
    if let savedState = coordinator.resolveCatalogFilterState(for: url) {
      restoreFilterState(savedState)
      if !appliedSelections.isEmpty {
        await applySingleFilters(coordinator: coordinator)
      } else {
        await fetchAndApplyFeed(at: url)
      }
    } else {
      await fetchAndApplyFeed(at: url)
    }
  }
  
  func fetchAndApplyFeed(at url: URL, clearFilters: Bool = false) async {
    do {
      if let feed = try await api.fetchFeed(at: url) {
        lanes.removeAll()
        ungroupedBooks.removeAll()
        facetGroups.removeAll()
        nextPageURL = nil
        
        let feedObjc = feed.opdsFeed
        extractNextPageURL(from: feedObjc)
        
        if let entries = feedObjc.entries as? [TPPOPDSEntry] {
          switch feedObjc.type {
          case .acquisitionGrouped:
            processGroupedFeed(entries: entries)
          case .acquisitionUngrouped:
            processUngroupedFeed(entries: entries, feedObjc: feedObjc)
          case .navigation, .invalid:
            break
          @unknown default:
            break
          }
        }
        
        // Only clear applied selections if explicitly requested (e.g., user cleared filters)
        if clearFilters {
          appliedSelections.removeAll()
          pendingSelections.removeAll()
        }
      }
    } catch {
      self.error = error.localizedDescription
    }
  }
  
  private func processGroupedFeed(entries: [TPPOPDSEntry]) {
    var orderedTitles: [String] = []
    var titleToBooks: [String: [TPPBook]] = [:]
    var titleToMoreURL: [String: URL?] = [:]
    
    for entry in entries {
      guard let group = entry.groupAttributes else { continue }
      let groupTitle = group.title ?? ""
      if let book = CatalogViewModel.makeBook(from: entry) {
        if titleToBooks[groupTitle] == nil { orderedTitles.append(groupTitle) }
        titleToBooks[groupTitle, default: []].append(book)
        if titleToMoreURL[groupTitle] == nil { titleToMoreURL[groupTitle] = group.href }
      }
    }
    
    lanes = orderedTitles.map { title in
      CatalogLaneModel(title: title, books: titleToBooks[title] ?? [], moreURL: titleToMoreURL[title] ?? nil)
    }
  }
  
  private func processUngroupedFeed(entries: [TPPOPDSEntry], feedObjc: TPPOPDSFeed) {
    ungroupedBooks = entries.compactMap { CatalogViewModel.makeBook(from: $0) }
    facetGroups = CatalogViewModel.extractFacets(from: feedObjc).0
    appliedSelections = Set(
      CatalogFilterService.selectionKeysFromActiveFacets(facetGroups: facetGroups, includeDefaults: false)
        .compactMap(CatalogFilterService.parseKey)
        .map { CatalogFilterService.makeGroupTitleKey(group: $0.group, title: $0.title) }
    )
  }
  
  // MARK: - Pagination
  
  private func extractNextPageURL(from feed: TPPOPDSFeed) {
    guard let links = feed.links as? [TPPOPDSLink] else { return }
    for link in links {
      if link.rel == "next" {
        nextPageURL = link.href
        break
      }
    }
  }
  
  func loadNextPage() async {
    guard let nextURL = nextPageURL, !isLoadingMore else { return }
    
    isLoadingMore = true
    defer { isLoadingMore = false }
    
    do {
      if let feed = try await api.fetchFeed(at: nextURL) {
        let feedObjc = feed.opdsFeed
        extractNextPageURL(from: feedObjc)
        
        if let entries = feedObjc.entries as? [TPPOPDSEntry] {
          let newBooks = entries.compactMap { CatalogViewModel.makeBook(from: $0) }
          ungroupedBooks.append(contentsOf: newBooks)
        }
      }
    } catch {
      Log.error(#file, "Failed to load next page: \(error.localizedDescription)")
    }
  }
  
  // MARK: - Registry Sync
  
  /// Refresh visible books with registry state (for downloaded/borrowed books)
  func applyRegistryUpdates(changedIdentifier: String?) {
    if !lanes.isEmpty {
      var newLanes = lanes
      for idx in newLanes.indices {
        var books = newLanes[idx].books
        var changed = false
        for bIdx in books.indices {
          let book = books[bIdx]
          if let changedIdentifier, book.identifier != changedIdentifier { continue }
          
          if let registryBook = TPPBookRegistry.shared.book(forIdentifier: book.identifier) {
            // Book is in registry - use registry version
            books[bIdx] = registryBook
            changed = true
          } else {
            // Book is NOT in registry (e.g., returned) - invalidate cached model
            BookCellModelCache.shared.invalidate(for: book.identifier)
            changed = true
          }
        }
        if changed {
          newLanes[idx] = CatalogLaneModel(
            title: newLanes[idx].title,
            books: books,
            moreURL: newLanes[idx].moreURL
          )
        }
      }
      lanes = newLanes
    }
    
    if !ungroupedBooks.isEmpty {
      var books = ungroupedBooks
      var anyChanged = false
      for idx in books.indices {
        let book = books[idx]
        if let changedIdentifier, book.identifier != changedIdentifier { continue }
        
        if let registryBook = TPPBookRegistry.shared.book(forIdentifier: book.identifier) {
          // Book is in registry - use registry version
          books[idx] = registryBook
          anyChanged = true
        } else {
          // Book is NOT in registry (e.g., returned) - invalidate cached model
          BookCellModelCache.shared.invalidate(for: book.identifier)
          anyChanged = true
        }
      }
      if anyChanged { ungroupedBooks = books }
    }
  }
  
  // MARK: - Filter Operations
  
  func applySingleFilters(coordinator: NavigationCoordinator) async {
    let specificFilters: [CatalogFilterService.ParsedKey] = pendingSelections
      .compactMap { selection in
        guard let parsed = CatalogFilterService.parseKey(selection) else { return nil }
        return parsed.isDefaultTitle ? nil : parsed
      }
    
    if specificFilters.isEmpty {
      // User explicitly cleared all filters - reload base feed and clear state
      await fetchAndApplyFeed(at: url, clearFilters: true)
      appliedSelections = []
      showingFiltersSheet = false
      saveFilterState(coordinator: coordinator)
      return
    }
    
    isApplyingFilters = true
    error = nil
    defer {
      isApplyingFilters = false
      showingFiltersSheet = false
    }
    
    do {
      // FRESH START: Reset to original feed (don't clear since we're applying new filters)
      await fetchAndApplyFeed(at: url, clearFilters: false)
      var currentFacetGroups = facetGroups
      
      // Sort filters by priority
      let sortedFilters = specificFilters.sorted { filter1, filter2 in
        let priority1 = CatalogFilterService.getGroupPriority(filter1.group)
        let priority2 = CatalogFilterService.getGroupPriority(filter2.group)
        return priority1 < priority2
      }
      
      // Apply each filter sequentially
      for filter in sortedFilters {
        if let filterURL = CatalogFilterService.findFilterInCurrentFacets(filter, in: currentFacetGroups) {
          if let feed = try await api.fetchFeed(at: filterURL) {
            if let entries = feed.opdsFeed.entries as? [TPPOPDSEntry] {
              ungroupedBooks = entries.compactMap { CatalogViewModel.makeBook(from: $0) }
            }
            
            if feed.opdsFeed.type == TPPOPDSFeedType.acquisitionUngrouped {
              currentFacetGroups = CatalogViewModel.extractFacets(from: feed.opdsFeed).0
            }
          }
        }
      }
      
      facetGroups = currentFacetGroups
      appliedSelections = Set(
        specificFilters.map { CatalogFilterService.makeGroupTitleKey(group: $0.group, title: $0.title) }
      )
      
      saveFilterState(coordinator: coordinator)
      
    } catch {
      self.error = error.localizedDescription
    }
  }
  
  func applyFacetHref(_ href: URL) async {
    isLoading = true
    error = nil
    defer { isLoading = false }
    await fetchAndApplyFeed(at: href)
  }
  
  func clearActiveFacets() async {
    for group in facetGroups {
      let facets = group.filters
      if facets.contains(where: { $0.active }), let first = facets.first, let href = first.href {
        await applyFacetHref(href)
      }
    }
  }
  
  // MARK: - OPDS Facet Selection
  
  func applyOPDSFacet(_ facet: CatalogFilter, coordinator: NavigationCoordinator) async {
    guard let href = facet.href else { return }
    
    isLoading = true
    error = nil
    defer { isLoading = false }
    
    await fetchAndApplyFeed(at: href)
    saveFilterState(coordinator: coordinator)
  }
  
  // MARK: - State Persistence
  
  func saveFilterState(coordinator: NavigationCoordinator) {
    let state = CatalogLaneFilterState(
      appliedSelections: appliedSelections,
      facetGroups: facetGroups
    )
    coordinator.storeCatalogFilterState(state, for: url)
  }
  
  func restoreFilterState(_ state: CatalogLaneFilterState) {
    appliedSelections = state.appliedSelections
    facetGroups = state.facetGroups
  }
  
  var sortFacets: [CatalogFilter] {
    return facetGroups
      .first { $0.name.lowercased().contains("sort") }?
      .filters ?? []
  }
  
  /// Get the currently active sort facet title (for display)
  var activeSortTitle: String? {
    return sortFacets.first { $0.active }?.title
  }
}
