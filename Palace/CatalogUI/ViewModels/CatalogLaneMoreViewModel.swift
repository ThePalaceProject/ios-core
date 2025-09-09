import Foundation
import Combine

@MainActor
final class CatalogLaneMoreViewModel: ObservableObject {
  // MARK: - Published Properties
  @Published private(set) var lanes: [CatalogLaneModel] = []
  @Published private(set) var ungroupedBooks: [TPPBook] = []
  @Published private(set) var isLoading = true
  @Published private(set) var error: String?
  @Published private(set) var facetGroups: [CatalogFilterGroup] = []
  @Published var currentSort: CatalogSort = .titleAZ
  @Published var appliedSelections: Set<String> = []
  @Published var isApplyingFilters: Bool = false
  
  // MARK: - Private Properties
  private let repository: CatalogRepositoryProtocol
  private let url: URL
  private var currentLoadTask: Task<Void, Never>?
  
  // MARK: - Computed Properties
  var activeFiltersCount: Int {
    appliedSelections.count
  }
  
  var allBooks: [TPPBook] {
    if !lanes.isEmpty {
      return lanes.flatMap { $0.books }
    }
    return ungroupedBooks
  }
  
  var sortedBooks: [TPPBook] {
    let books = allBooks.map { TPPBookRegistry.shared.updatedBookMetadata($0) ?? $0 }
    return sortBooks(books, by: currentSort)
  }
  
  // MARK: - Initialization
  init(url: URL, repository: CatalogRepositoryProtocol = CatalogRepository()) {
    self.url = url
    self.repository = repository
  }
  
  // MARK: - Public Methods
  func load() async {
    await fetchAndApplyFeed(at: url)
  }
  
  func refresh() async {
    (repository as? CatalogRepository)?.invalidateCache(for: url)
    await fetchAndApplyFeed(at: url)
  }
  
  func applySort(_ sort: CatalogSort) async {
    currentSort = sort
    // Re-sort the existing data
    if !lanes.isEmpty {
      lanes = lanes.map { lane in
        CatalogLaneModel(
          title: lane.title,
          books: sortBooks(lane.books, by: sort),
          moreURL: lane.moreURL
        )
      }
    } else {
      ungroupedBooks = sortBooks(ungroupedBooks, by: sort)
    }
  }
  
  func applyFilters(_ selections: Set<String>) async {
    guard !selections.isEmpty else { return }
    
    isApplyingFilters = true
    appliedSelections = selections
    
    // Find the filter URLs to apply
    var filterURLs: [URL] = []
    for group in facetGroups {
      for filter in group.filters {
        if selections.contains(filter.id), let href = filter.href {
          filterURLs.append(href)
        }
      }
    }
    
    // Apply the first filter URL (simplified approach)
    if let firstURL = filterURLs.first {
      await fetchAndApplyFeed(at: firstURL)
    }
    
    isApplyingFilters = false
  }
  
  func clearFilters() async {
    appliedSelections.removeAll()
    await fetchAndApplyFeed(at: url)
  }
}

// MARK: - Private Methods
private extension CatalogLaneMoreViewModel {
  func fetchAndApplyFeed(at url: URL) async {
    currentLoadTask?.cancel()
    currentLoadTask = Task { [weak self] in
      guard let self else { return }
      
      do {
        isLoading = true
        error = nil
        
        guard let feed = try await repository.loadTopLevelCatalog(at: url) else {
          await MainActor.run { self.error = "Failed to load catalog" }
          return
        }
        
        let mapped = await Task.detached(priority: .userInitiated) {
          return await CatalogViewModel.mapFeed(feed)
        }.value
        
        if Task.isCancelled { return }
        
        await MainActor.run {
          self.lanes = mapped.lanes
          self.ungroupedBooks = mapped.ungroupedBooks
          self.facetGroups = mapped.facetGroups
          self.isLoading = false
        }
      } catch {
        if Task.isCancelled { return }
        await MainActor.run {
          self.error = error.localizedDescription
          self.isLoading = false
        }
      }
    }
  }
  
  func sortBooks(_ books: [TPPBook], by sort: CatalogSort) -> [TPPBook] {
    switch sort {
    case .titleAZ:
      return books.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    case .titleZA:
      return books.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
    case .authorAZ:
      return books.sorted { ($0.authors ?? "").localizedCaseInsensitiveCompare($1.authors ?? "") == .orderedAscending }
    case .authorZA:
      return books.sorted { ($0.authors ?? "").localizedCaseInsensitiveCompare($1.authors ?? "") == .orderedDescending }
    }
  }
}
