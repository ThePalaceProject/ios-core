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

  private let repository: CatalogRepositoryProtocol
  private let topLevelURLProvider: () -> URL?
  private var lastLoadedURL: URL?
  private var currentLoadTask: Task<Void, Never>? = nil

  init(repository: CatalogRepositoryProtocol, topLevelURLProvider: @escaping () -> URL?) {
    self.repository = repository
    self.topLevelURLProvider = topLevelURLProvider
  }

  // MARK: - Public API

  func load() async {
    if !lanes.isEmpty || !ungroupedBooks.isEmpty { return }
    guard let url = topLevelURLProvider() else { return }
    isLoading = true
    errorMessage = nil

    currentLoadTask?.cancel()
    currentLoadTask = Task { [weak self] in
      guard let self else { return }
      do {
        guard let feed = try await self.repository.loadTopLevelCatalog(at: url) else {
          await MainActor.run { self.errorMessage = "Failed to load catalog" }
          return
        }

        let mapped = await Task.detached(priority: .userInitiated) { () -> MappedCatalog in
          return await Self.mapFeed(feed)
        }.value

        if Task.isCancelled { return }
        await MainActor.run {
          self.title = mapped.title
          self.entries = mapped.entries
          self.lanes = mapped.lanes
          self.ungroupedBooks = mapped.ungroupedBooks
          self.facetGroups = mapped.facetGroups
          self.entryPoints = mapped.entryPoints
          self.lastLoadedURL = url
          self.isLoading = false
        }

        // Prefetch some thumbnails to speed perceived loading
        if !mapped.lanes.isEmpty {
          self.prefetchThumbnails(for: mapped.lanes.first?.books ?? [])
        } else if !mapped.ungroupedBooks.isEmpty {
          self.prefetchThumbnails(for: Array(mapped.ungroupedBooks.prefix(20)))
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
  func applyFacet(_ facet: CatalogFilter) async {
    guard let href = facet.href else { return }
    errorMessage = nil
    do {
      if let feed = try await repository.loadTopLevelCatalog(at: href) {
        let feedObjc = feed.opdsFeed
        switch feedObjc.type {
        case .acquisitionUngrouped:
          if let opdsEntries = feedObjc.entries as? [TPPOPDSEntry] {
            let newUngrouped = opdsEntries.compactMap { Self.makeBook(from: $0) }
            self.lanes = []
            self.ungroupedBooks = newUngrouped
          }
          let (groups, entries) = Self.extractFacets(from: feedObjc)
          self.facetGroups = groups
          self.entryPoints = entries
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
          let (_, entries) = Self.extractFacets(from: feedObjc)
          self.facetGroups = []
          self.entryPoints = entries
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
  func applyEntryPoint(_ facet: CatalogFilter) async {
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
          let (groups, entries) = Self.extractFacets(from: feedObjc)
          self.facetGroups = groups
          self.entryPoints = entries
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
          let (_, entries) = Self.extractFacets(from: feedObjc)
          self.entryPoints = entries
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
      let ungroupedBooks = (feedObjc.entries as? [TPPOPDSEntry])?.compactMap { makeBookBackground(from: $0) } ?? []
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

  private static func buildGroupedContent(from feed: TPPOPDSFeed) -> ([CatalogLaneModel], [TPPBook]) {
    var titleToBooks: [String: [TPPBook]] = [:]
    var titleToMoreURL: [String: URL?] = [:]
    if let entries = feed.entries as? [TPPOPDSEntry] {
      for entry in entries {
        if let group = entry.groupAttributes,
           let book = makeBookBackground(from: entry) {
          let title = group.title ?? ""
          titleToBooks[title, default: []].append(book)
          if titleToMoreURL[title] == nil { titleToMoreURL[title] = group.href }
        }
      }
    }
    let lanes = titleToBooks
      .map { title, books in CatalogLaneModel(title: title, books: books, moreURL: titleToMoreURL[title] ?? nil) }
      .sorted { $0.title < $1.title }
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


