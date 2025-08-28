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
  @Published var isContentReloading: Bool = false

  private let repository: CatalogRepositoryProtocol
  private let topLevelURLProvider: () -> URL?
  private var lastLoadedURL: URL?
  private var currentLoadTask: Task<Void, Never>? = nil

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

    // Cancel any in-flight load and start a new one
    currentLoadTask?.cancel()
    currentLoadTask = Task { [weak self] in
      guard let self else { return }
      do {
        guard let feed = try await self.repository.loadTopLevelCatalog(at: url) else {
          await MainActor.run { self.errorMessage = "Failed to load catalog" }
          return
        }

        // Map feed off the main actor to reduce UI contention
        let mapped = try await Task.detached(priority: .userInitiated) { () -> (title: String, entries: [CatalogEntry], lanes: [CatalogLaneModel], ungrouped: [TPPBook], facets: [TPPCatalogFacetGroup], entryPoints: [TPPCatalogFacet]) in
          let title = feed.title
          let entries = feed.entries
          var lanesOut: [CatalogLaneModel] = []
          var ungroupedOut: [TPPBook] = []
          var facetsOut: [TPPCatalogFacetGroup] = []
          var entryPointsOut: [TPPCatalogFacet] = []
          let feedObjc = feed.opdsFeed
          switch feedObjc.type {
          case .acquisitionGrouped:
            if let grouped = TPPCatalogGroupedFeed(opdsFeed: feedObjc) {
              entryPointsOut = grouped.entryPoints
            }
            var groupTitleToBooks: [String: [TPPBook]] = [:]
            var groupTitleToMoreURL: [String: URL?] = [:]
            if let opdsEntries = feedObjc.entries as? [TPPOPDSEntry] {
              for entry in opdsEntries {
                if Task.isCancelled { break }
                guard let group = entry.groupAttributes else { continue }
                let groupTitle = group.title ?? ""
                if let book = Self.makeBookBackground(from: entry) {
                  groupTitleToBooks[groupTitle, default: []].append(book)
                  if groupTitleToMoreURL[groupTitle] == nil { groupTitleToMoreURL[groupTitle] = group.href }
                }
              }
            }
            lanesOut = groupTitleToBooks.map { title, books in
              CatalogLaneModel(title: title, books: books, moreURL: groupTitleToMoreURL[title] ?? nil)
            }.sorted { $0.title < $1.title }
          case .acquisitionUngrouped:
            if let opdsEntries = feedObjc.entries as? [TPPOPDSEntry] {
              ungroupedOut = opdsEntries.compactMap { Self.makeBookBackground(from: $0) }
            }
            if let ungrouped = TPPCatalogUngroupedFeed(opdsFeed: feedObjc) {
              facetsOut = (ungrouped.facetGroups as? [TPPCatalogFacetGroup]) ?? []
              entryPointsOut = ungrouped.entryPoints
            }
          case .navigation, .invalid:
            break
          @unknown default:
            break
          }
          return (title, entries, lanesOut, ungroupedOut, facetsOut, entryPointsOut)
        }.value

        if Task.isCancelled { return }
        await MainActor.run {
          self.title = mapped.title
          self.entries = mapped.entries
          self.lanes = mapped.lanes
          self.ungroupedBooks = mapped.ungrouped
          self.facetGroups = mapped.facets
          self.entryPoints = mapped.entryPoints
          self.lastLoadedURL = url
          self.isLoading = false
        }

        // Prefetch some thumbnails to speed perceived loading
        if !mapped.lanes.isEmpty {
          self.prefetchThumbnails(for: mapped.lanes.first?.books ?? [])
        } else if !mapped.ungrouped.isEmpty {
          self.prefetchThumbnails(for: Array(mapped.ungrouped.prefix(20)))
        }
      } catch {
        if Task.isCancelled { return }
        await MainActor.run {
          self.errorMessage = error.localizedDescription
          self.isLoading = false
        }
      }
    }
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

  /// Applies an entry point (e.g., Ebooks/Audiobooks) and shows skeleton while loading.
  @MainActor
  func applyEntryPoint(_ facet: TPPCatalogFacet) async {
    guard let href = facet.href else { return }
    // Keep top-level skeleton off; only show content skeleton
    isContentReloading = true
    errorMessage = nil
    lanes.removeAll()
    ungroupedBooks.removeAll()
    currentLoadTask?.cancel()
    do {
      if let feed = try await repository.loadTopLevelCatalog(at: href) {
        let feedObjc = feed.opdsFeed
        switch feedObjc.type {
        case .acquisitionUngrouped:
          if let opdsEntries = feedObjc.entries as? [TPPOPDSEntry] {
            self.ungroupedBooks = opdsEntries.compactMap { Self.makeBook(from: $0) }
          }
          if let ungrouped = TPPCatalogUngroupedFeed(opdsFeed: feedObjc) {
            self.facetGroups = (ungrouped.facetGroups as? [TPPCatalogFacetGroup]) ?? []
            self.entryPoints = ungrouped.entryPoints
          } else {
            self.facetGroups = []
          }
        case .acquisitionGrouped:
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
          if let grouped = TPPCatalogGroupedFeed(opdsFeed: feedObjc) {
            self.entryPoints = grouped.entryPoints
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
    isContentReloading = false
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
}

// MARK: - Helpers

extension CatalogViewModel {
  private func prefetchThumbnails(for books: [TPPBook]) {
    let set = Set(books)
    TPPBookRegistry.shared.thumbnailImages(forBooks: set) { _ in }
  }
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

  nonisolated static func makeBookBackground(from entry: TPPOPDSEntry) -> TPPBook? {
    guard let book = TPPBook(entry: entry) else { return nil }
    if book.defaultBookContentType == .unsupported { return nil }
    if book.defaultAcquisition == nil { return nil }
    return book
  }
}


