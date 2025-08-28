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
  @Published private(set) var facetGroups: [TPPCatalogFacetGroup] = []
  @Published private(set) var entryPoints: [TPPCatalogFacet] = []

  private let repository: CatalogRepositoryProtocol
  private let topLevelURLProvider: () -> URL?
  private var lastLoadedURL: URL?

  init(repository: CatalogRepositoryProtocol, topLevelURLProvider: @escaping () -> URL?) {
    self.repository = repository
    self.topLevelURLProvider = topLevelURLProvider
  }

  func load() async {
    // Avoid reloading if we already have data
    if !lanes.isEmpty || !ungroupedBooks.isEmpty { return }
    guard let url = topLevelURLProvider() else { return }
    isLoading = true
    errorMessage = nil
    
    do {
      guard let feed = try await repository.loadTopLevelCatalog(at: url) else {
        errorMessage = "Failed to load catalog"
        return
      }
    
      title = feed.title
      entries = feed.entries

      // Map OPDS into lanes or ungrouped books
      lanes.removeAll()
      ungroupedBooks.removeAll()
      let feedObjc = feed.opdsFeed
      switch feedObjc.type {
      case .acquisitionGrouped:
        // Entry points for grouped feeds (e.g., Audiobooks, Ebooks)
        let grouped = TPPCatalogGroupedFeed(opdsFeed: feedObjc)
        entryPoints = grouped?.entryPoints ?? []
        var groupTitleToBooks: [String: [TPPBook]] = [:]
        var groupTitleToMoreURL: [String: URL?] = [:]
        if let opdsEntries = feedObjc.entries as? [TPPOPDSEntry] {
          for entry in opdsEntries {
            guard let group = entry.groupAttributes else { continue }
            let groupTitle = group.title ?? ""
            if let book = Self.makeBook(from: entry) {
              groupTitleToBooks[groupTitle, default: []].append(book)
              if groupTitleToMoreURL[groupTitle] == nil {
                groupTitleToMoreURL[groupTitle] = group.href
              }
            }
          }
        }
        lanes = groupTitleToBooks.map { title, books in
          CatalogLaneModel(title: title, books: books, moreURL: groupTitleToMoreURL[title] ?? nil)
        }.sorted { $0.title < $1.title }
      case .acquisitionUngrouped:
        if let opdsEntries = feedObjc.entries as? [TPPOPDSEntry] {
          ungroupedBooks = opdsEntries.compactMap { Self.makeBook(from: $0) }
        }
        // Load facet groups for filtering/sorting
        let ungrouped = TPPCatalogUngroupedFeed(opdsFeed: feedObjc)
        facetGroups = (ungrouped?.facetGroups as? [TPPCatalogFacetGroup]) ?? []
        entryPoints = ungrouped?.entryPoints ?? []
      case .navigation, .invalid:
        break
      @unknown default:
        break
      }
      lastLoadedURL = url
    } catch {
      errorMessage = error.localizedDescription
    }
    isLoading = false
  }

  func refresh() async {
    guard let url = topLevelURLProvider() else { return }
    (repository as? CatalogRepository)?.invalidateCache(for: url)
    lanes.removeAll()
    ungroupedBooks.removeAll()
    entryPoints.removeAll()
    await load()
  }

  @MainActor
  func applyFacet(_ facet: TPPCatalogFacet) async {
    guard let href = facet.href else { return }
    errorMessage = nil
    do {
      if let feed = try await repository.loadTopLevelCatalog(at: href) {
        let feedObjc = feed.opdsFeed
        switch feedObjc.type {
        case .acquisitionUngrouped:
          if let opdsEntries = feedObjc.entries as? [TPPOPDSEntry] {
            let newUngrouped = opdsEntries.compactMap { Self.makeBook(from: $0) }
            // Swap atomically to avoid flicker
            self.lanes = []
            self.ungroupedBooks = newUngrouped
          }
          if let ungrouped = TPPCatalogUngroupedFeed(opdsFeed: feedObjc) {
            self.facetGroups = (ungrouped.facetGroups as? [TPPCatalogFacetGroup]) ?? []
            self.entryPoints = ungrouped.entryPoints
          } else {
            self.facetGroups = []
            self.entryPoints = []
          }
        case .acquisitionGrouped:
          // Rebuild lanes instead of flattening
          var groupTitleToBooks: [String: [TPPBook]] = [:]
          var groupTitleToMoreURL: [String: URL?] = [:]
          if let opdsEntries = feedObjc.entries as? [TPPOPDSEntry] {
            for entry in opdsEntries {
              guard let group = entry.groupAttributes else { continue }
              let groupTitle = group.title ?? ""
              if let book = Self.makeBook(from: entry) {
                groupTitleToBooks[groupTitle, default: []].append(book)
                if groupTitleToMoreURL[groupTitle] == nil { groupTitleToMoreURL[groupTitle] = group.href }
              }
            }
          }
          self.ungroupedBooks = []
          self.facetGroups = []
          if let grouped = TPPCatalogGroupedFeed(opdsFeed: feedObjc) {
            self.entryPoints = grouped.entryPoints
          } else {
            self.entryPoints = []
          }
          self.lanes = groupTitleToBooks.map { title, books in
            CatalogLaneModel(title: title, books: books, moreURL: groupTitleToMoreURL[title] ?? nil)
          }.sorted { $0.title < $1.title }
        case .navigation, .invalid:
          break
        @unknown default:
          break
        }
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func handleAccountChange() async {
    guard let url = topLevelURLProvider() else { return }
    // Only refresh if the URL actually changed, to prevent double-load on startup
    if lastLoadedURL == nil || url != lastLoadedURL {
      // Immediately show loading state and clear previous content while new feed loads
      await MainActor.run {
        self.isLoading = true
        self.errorMessage = nil
        self.lanes.removeAll()
        self.ungroupedBooks.removeAll()
      }
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
}

// MARK: - Helpers

extension CatalogViewModel {
  static func makeBook(from entry: TPPOPDSEntry) -> TPPBook? {
    guard var book = TPPBook(entry: entry) else { return nil }
    // Update metadata from registry
    if let updated = TPPBookRegistry.shared.updatedBookMetadata(book) {
      book = updated
    }
    // Filter unsupported
    if book.defaultBookContentType == .unsupported { return nil }
    if book.defaultAcquisition == nil { return nil }
    return book
  }
}


