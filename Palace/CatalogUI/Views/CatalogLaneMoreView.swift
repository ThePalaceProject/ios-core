import SwiftUI

struct CatalogLaneMoreView: View {
  var title: String = ""
  let url: URL

  @State private var lanes: [CatalogLaneModel] = []
  @State private var ungroupedBooks: [TPPBook] = []
  @State private var isLoading = true
  @State private var error: String?
  @StateObject private var logoObserver = CatalogLogoObserver()
  @State private var currentAccountUUID: String = AccountsManager.shared.currentAccount?.uuid ?? ""

  @State private var facetGroups: [CatalogFilterGroup] = []
  @State private var showingSortSheet: Bool = false
  @State private var showingFiltersSheet: Bool = false
  @State private var currentSort: CatalogSort = .titleAZ

  @State private var pendingSelections: Set<String> = []
  @State private var appliedSelections: Set<String> = []
  @State private var isApplyingFilters: Bool = false

  // MARK: - Audiobook Sample Toolbar
  @State private var sampleToolbar: AudiobookSampleToolbar? = nil
  @State private var currentSampleBookID: String? = nil

  var body: some View {
    VStack(spacing: 0) {
      if !facetGroups.isEmpty {
        FacetToolbarView(
          title: title,
          showFilter: true,
          onSort: { showingSortSheet = true },
          onFilter: { showingFiltersSheet = true },
          currentSortTitle: currentSort.localizedString,
          appliedFiltersCount: activeFiltersCount
        )
        .padding(.bottom, 5)
        .overlay(alignment: .trailing) {
          if isLoading || isApplyingFilters {
            ProgressView().padding(.trailing, 12)
          }
        }
        Divider()
      }

      if isLoading {
        ScrollView {
          VStack(alignment: .leading, spacing: 24) {
            ForEach(0..<3, id: \.self) { _ in
              CatalogLaneSkeletonView()
            }
          }
          .padding(.vertical, 12)
          .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let error {
        Text(error).padding()
      } else if !lanes.isEmpty {
        ScrollView {
          VStack(alignment: .leading, spacing: 24) {
            ForEach(lanes) { lane in
              CatalogLaneRowView(
                title: lane.title,
                books: lane.books,
                moreURL: lane.moreURL,
                onSelect: { presentBookDetail($0) },
                showHeader: true
              )
            }
          }
          .padding(.vertical, 12)
        }
        .refreshable { await fetchAndApplyFeed(at: url) }
      } else {
        BookListView(books: ungroupedBooks, isLoading: $isLoading) { book in
          presentBookDetail(book)
        }
        .refreshable { await fetchAndApplyFeed(at: url) }
      }
    }
    .overlay(alignment: .bottom) {
      if let toolbar = sampleToolbar {
        VStack(spacing: 0) {
          Spacer(minLength: 0)
          toolbar
        }
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) {
        LibraryNavTitleView(onTap: { openLibraryHome() })
          .id(logoObserver.token.uuidString + currentAccountUUID)
      }
    }
    .task { await load() }
    .onAppear {
      if NavigationCoordinatorHub.shared.coordinator == nil {
        NavigationCoordinatorHub.shared.coordinator = coordinator
      }
    }
    .onAppear {
      let account = AccountsManager.shared.currentAccount
      account?.logoDelegate = logoObserver
      account?.loadLogo()
      currentAccountUUID = account?.uuid ?? ""
    }
    .onReceive(NotificationCenter.default.publisher(for: .TPPCurrentAccountDidChange)) { _ in
      let account = AccountsManager.shared.currentAccount
      account?.logoDelegate = logoObserver
      account?.loadLogo()
      currentAccountUUID = account?.uuid ?? ""

      appliedSelections.removeAll()
      pendingSelections.removeAll()
      Task { await load() }
    }
    // Show/Toggle audiobook preview bar when sample is triggered
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ToggleSampleNotification")).receive(on: RunLoop.main)) { note in
      guard
        let info = note.userInfo as? [String: Any],
        let identifier = info["bookIdentifier"] as? String
      else { return }

      // Toggle close if the same book is already showing
      if let current = currentSampleBookID, current == identifier, let toolbar = sampleToolbar {
        toolbar.player.pauseAudiobook()
        withAnimation {
          sampleToolbar = nil
          currentSampleBookID = nil
        }
        return
      }

      if let book = TPPBookRegistry.shared.book(forIdentifier: identifier) ??
          (lanes.flatMap { $0.books } + ungroupedBooks).first(where: { $0.identifier == identifier }) {
        sampleToolbar = AudiobookSampleToolbar(book: book)
        currentSampleBookID = identifier
      }
      // Toolbar itself toggles play on this notification
    }
    .onReceive(NotificationCenter.default.publisher(for: .TPPBookRegistryDidChange).receive(on: RunLoop.main)) { _ in
      applyRegistryUpdates()
    }
    .onReceive(NotificationCenter.default.publisher(for: .TPPBookRegistryStateDidChange).receive(on: RunLoop.main)) { _ in
      applyRegistryUpdates()
    }
    .onReceive(NotificationCenter.default.publisher(for: .TPPMyBooksDownloadCenterDidChange).receive(on: RunLoop.main)) { _ in
      applyRegistryUpdates()
    }
    .onChange(of: showingFiltersSheet) { presented in
      guard presented else { return }
      if !appliedSelections.isEmpty {
        pendingSelections = keysForCurrentFacets(fromGroupTitleKeys: appliedSelections)
      } else {
        pendingSelections = selectionKeysFromActiveFacets(includeDefaults: true)
      }
    }
    .onChange(of: currentSort) { _ in
      sortBooksInPlace()
    }
    .sheet(isPresented: $showingSortSheet) {
      SortOptionsSheet
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    .sheet(isPresented: $showingFiltersSheet) {
      FiltersSheetWrapper
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
  }

  // MARK: - Loading

  @MainActor
  private func load() async {
    isLoading = true
    error = nil
    defer { isLoading = false }
    await fetchAndApplyFeed(at: url)
  }

  

  @MainActor
  private func fetchAndApplyFeed(at url: URL) async {
    do {
      let client = URLSessionNetworkClient()
      let parser = OPDSParser()
      let api = DefaultCatalogAPI(client: client, parser: parser)

      if let feed = try await api.fetchFeed(at: url) {
        lanes.removeAll()
        ungroupedBooks.removeAll()
        facetGroups.removeAll()

        let feedObjc = feed.opdsFeed
        if let entries = feedObjc.entries as? [TPPOPDSEntry] {
          switch feedObjc.type {
          case .acquisitionGrouped:
            var groupTitleToBooks: [String: [TPPBook]] = [:]
            var groupTitleToMoreURL: [String: URL?] = [:]
            for entry in entries {
              guard let group = entry.groupAttributes else { continue }
              let groupTitle = group.title ?? ""
              if let book = CatalogViewModel.makeBook(from: entry) {
                groupTitleToBooks[groupTitle, default: []].append(book)
                if groupTitleToMoreURL[groupTitle] == nil { groupTitleToMoreURL[groupTitle] = group.href }
              }
            }
            lanes = groupTitleToBooks.map { title, books in
              CatalogLaneModel(title: title, books: books, moreURL: groupTitleToMoreURL[title] ?? nil)
            }.sorted { $0.title < $1.title }
          case .acquisitionUngrouped:
            ungroupedBooks = entries.compactMap { CatalogViewModel.makeBook(from: $0) }
            facetGroups = CatalogViewModel.extractFacets(from: feedObjc).0
            appliedSelections = Set(
              selectionKeysFromActiveFacets(includeDefaults: false)
                .compactMap(parseKey)
                .map { makeGroupTitleKey(group: $0.group, title: $0.title) }
            )
            sortBooksInPlace()
          case .navigation, .invalid:
            break
          @unknown default:
            break
          }
        }
      }
    } catch {
      self.error = error.localizedDescription
    }
  }

  // MARK: - Registry Sync

  /// Refresh visible books with updated metadata from the registry so button states reflect current status.
  private func applyRegistryUpdates() {
    if !lanes.isEmpty {
      lanes = lanes.map { lane in
        let updated = lane.books.map { book in
          TPPBookRegistry.shared.updatedBookMetadata(book) ?? book
        }
        return CatalogLaneModel(title: lane.title, books: updated, moreURL: lane.moreURL)
      }
    }

    if !ungroupedBooks.isEmpty {
      ungroupedBooks = ungroupedBooks.map { book in
        TPPBookRegistry.shared.updatedBookMetadata(book) ?? book
      }
    }
  }

  // MARK: - Navigation

  @EnvironmentObject private var coordinator: NavigationCoordinator

  private func presentBookDetail(_ book: TPPBook) {
    if NavigationCoordinatorHub.shared.coordinator == nil {
      NavigationCoordinatorHub.shared.coordinator = coordinator
    }
    coordinator.store(book: book)
    coordinator.push(.bookDetail(BookRoute(id: book.identifier)))
  }

  private func openLibraryHome() {
    if let urlString = AccountsManager.shared.currentAccount?.homePageUrl, let url = URL(string: urlString) {
      UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
  }

  // MARK: - Facets

  @MainActor
  private func applyFacetHref(_ href: URL) async {
    isLoading = true
    error = nil
    defer { isLoading = false }
    await fetchAndApplyFeed(at: href)
  }

  @MainActor
  private func clearActiveFacets() async {
    for group in facetGroups {
      let facets = group.filters
      if facets.contains(where: { $0.active }), let first = facets.first, let href = first.href {
        await applyFacetHref(href)
      }
    }
  }

  // MARK: - Filter Sheet

  private var FiltersSheetWrapper: some View {
    CatalogFiltersSheetView(
      facetGroups: facetGroups,
      selection: $pendingSelections,
      onApply: { Task { await applyPendingFacets() } },
      isApplying: isApplyingFilters
    )
  }

  @MainActor
  private func applyPendingFacets() async {
    let desiredHrefs: [URL] = pendingSelections
      .compactMap(parseKey) 
      .filter { !$0.isDefaultTitle }
      .compactMap { URL(string: $0.hrefString) }

    if desiredHrefs.isEmpty {
      isLoading = true
      isApplyingFilters = true
      error = nil
      defer {
        isLoading = false
        isApplyingFilters = false
        showingFiltersSheet = false
      }
      await fetchAndApplyFeed(at: url)
      appliedSelections = []
      pendingSelections = selectionKeysFromActiveFacets(includeDefaults: true)
      return
    }

    let currentHrefs = activeFacetHrefs(includeDefaults: false)
    if Set(desiredHrefs) == Set(currentHrefs) {
      showingFiltersSheet = false
      return
    }

    isLoading = true
    isApplyingFilters = true
    error = nil
    defer {
      isLoading = false
      isApplyingFilters = false
      showingFiltersSheet = false
    }

    var workingGroups = facetGroups
    do {
      let client = URLSessionNetworkClient()
      let parser = OPDSParser()
      let api = DefaultCatalogAPI(client: client, parser: parser)

      for href in desiredHrefs.sorted(by: { $0.absoluteString < $1.absoluteString }) {
        if let feed = try await api.fetchFeed(at: href) {
          if let entries = feed.opdsFeed.entries as? [TPPOPDSEntry] {
            ungroupedBooks = entries.compactMap { CatalogViewModel.makeBook(from: $0) }
            sortBooksInPlace()
          }
          if feed.opdsFeed.type == TPPOPDSFeedType.acquisitionUngrouped {
            workingGroups = CatalogViewModel.extractFacets(from: feed.opdsFeed).0
          }
        }
      }

      facetGroups = workingGroups
      appliedSelections = Set(
        pendingSelections
          .compactMap(parseKey)
          .filter { !$0.isDefaultTitle }
          .map { makeGroupTitleKey(group: $0.group, title: $0.title) }
      )
      pendingSelections = keysForCurrentFacets(fromGroupTitleKeys: appliedSelections)

    } catch {
      self.error = error.localizedDescription
    }
  }

  // MARK: - Sort

  private enum CatalogSort: CaseIterable {
    case authorAZ, authorZA, recentlyAddedAZ, recentlyAddedZA, titleAZ, titleZA

    var localizedString: String {
      switch self {
      case .authorAZ: return "Author (A-Z)"
      case .authorZA: return "Author (Z-A)"
      case .recentlyAddedAZ: return "Recently Added (A-Z)"
      case .recentlyAddedZA: return "Recently Added (Z-A)"
      case .titleAZ: return "Title (A-Z)"
      case .titleZA: return "Title (Z-A)"
      }
    }
  }

  private func sortBooksInPlace() {
    switch currentSort {
    case .authorAZ:
      ungroupedBooks.sort { (($0.authors ?? "") + " " + $0.title) < (($1.authors ?? "") + " " + $1.title) }
    case .authorZA:
      ungroupedBooks.sort { (($0.authors ?? "") + " " + $0.title) > (($1.authors ?? "") + " " + $1.title) }
    case .recentlyAddedAZ:
      ungroupedBooks.sort { $0.updated < $1.updated }
    case .recentlyAddedZA:
      ungroupedBooks.sort { $0.updated > $1.updated }
    case .titleAZ:
      ungroupedBooks.sort { ($0.title + " " + ($0.authors ?? "")) < ($1.title + " " + ($1.authors ?? "")) }
    case .titleZA:
      ungroupedBooks.sort { ($0.title + " " + ($0.authors ?? "")) > ($1.title + " " + ($1.authors ?? "")) }
    }
  }

  // MARK: - Keys & Helpers

  private struct ParsedKey {
    let group: String
    let title: String
    let hrefString: String
    var isDefaultTitle: Bool {
      let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return t == "all" || t == "all formats" || t == "all collections" || t == "all distributors"
    }
  }

  /// Canonical key is "group|title|href"
  private func makeKey(group: String, title: String, hrefString: String) -> String {
    "\(group)|\(title)|\(hrefString)"
  }
  /// Group-title-only key
  private func makeGroupTitleKey(group: String, title: String) -> String {
    "\(group)|\(title)"
  }

  private func parseKey(_ key: String) -> ParsedKey? {
    let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 3 else { return nil }
    return ParsedKey(group: parts[0], title: parts[1], hrefString: parts[2])
  }

  /// Map stored group|title selections to current facet keys with up-to-date hrefs
  private func keysForCurrentFacets(fromGroupTitleKeys keys: Set<String>) -> Set<String> {
    var out: Set<String> = []
    let wanted: [String: Set<String>] = Dictionary(grouping: keys.compactMap { key -> (String, String)? in
      let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
      guard parts.count >= 2 else { return nil }
      return (parts[0], parts[1])
    }) { $0.0 }.mapValues { Set($0.map { normalizeTitle($0.1) }) }
    for group in facetGroups where !group.name.lowercased().contains("sort") {
      let titles = wanted[group.name] ?? []
      let facets = group.filters
      var foundAnyInGroup = false
      for facet in facets {
        let title = facet.title
        if titles.contains(normalizeTitle(title)) {
          let href = facet.href?.absoluteString ?? ""
          out.insert(makeKey(group: group.name, title: title, hrefString: href))
          foundAnyInGroup = true
        }
      }
      // Ensure at least All if nothing matched for this group
      if !foundAnyInGroup {
        if let allFacet = facets.first(where: { ($0.title).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "all" }) {
          out.insert(makeKey(group: group.name, title: allFacet.title, hrefString: allFacet.href?.absoluteString ?? ""))
        }
      }
    }
    return out
  }

  private func normalizeTitle(_ title: String) -> String {
    title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  /// Extract active facet keys from the current groups.
  private func selectionKeysFromActiveFacets(includeDefaults: Bool) -> Set<String> {
    var out: [String] = []
    for group in facetGroups {
      if group.name.lowercased().contains("sort") { continue }
      let facets = group.filters.filter { $0.active }
      for facet in facets {
        let rawTitle = facet.title
        let parsed = ParsedKey(group: group.name, title: rawTitle, hrefString: facet.href?.absoluteString ?? "")
        if includeDefaults || !parsed.isDefaultTitle {
          out.append(makeKey(group: parsed.group, title: rawTitle, hrefString: parsed.hrefString))
        }
      }
    }
    return Set(out)
  }

  /// The hrefs of **currently active** facets.
  private func activeFacetHrefs(includeDefaults: Bool) -> [URL] {
    facetGroups
      .filter { !$0.name.lowercased().contains("sort") }
      .flatMap { group in
        group.filters
          .filter { $0.active }
          .compactMap { facet -> (String, URL)? in
            let title = facet.title
            let url = facet.href
            guard let url else { return nil }
            let parsed = ParsedKey(group: group.name, title: title, hrefString: url.absoluteString)
            return (includeDefaults || !parsed.isDefaultTitle) ? (title, url) : nil
          }
      }
      .map { $0.1 }
  }

  private var activeFiltersCount: Int {
    appliedSelections.count
  }
  
  private var SortOptionsSheet: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(Strings.Catalog.sortBy)
        .font(.headline)
        .padding(.horizontal)
        .padding(.top, 12)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(CatalogSort.allCases, id: \.self) { sort in
            Button(action: { currentSort = sort }) {
              HStack {
                Image(systemName: currentSort == sort ? "largecircle.fill.circle" : "circle")
                  .foregroundColor(.primary)
                Text(sort.localizedString)
                  .foregroundColor(.primary)
                Spacer()
              }
              .padding(.vertical, 12)
              .padding(.horizontal)
            }
            .buttonStyle(.plain)
          }
        }
      }
      .background(Color(UIColor.systemBackground))
    }
  }
}
