import SwiftUI
import Combine

// MARK: - Filter State Management

struct FilterState {
  let appliedFilter: String  // The filter that was applied to get to this state
  let books: [TPPBook]
  let facetGroups: [CatalogFilterGroup]
  let feedURL: URL
  let selectedFilters: Set<String>  // All filters applied up to this point
}

struct CatalogLaneMoreView: View {
  // MARK: - Properties
  
  let title: String
  let url: URL
  
  // MARK: - Content State

  @State private var lanes: [CatalogLaneModel] = []
  @State private var ungroupedBooks: [TPPBook] = []
  @State private var isLoading = true
  @State private var error: String?
  
  // MARK: - UI State

  @State private var showingSortSheet: Bool = false
  @State private var showingFiltersSheet: Bool = false
  @State private var showSearch: Bool = false
  
  // MARK: - Filter State

  @State private var facetGroups: [CatalogFilterGroup] = []
  @State private var pendingSelections: Set<String> = []
  @State private var appliedSelections: Set<String> = []
  @State private var isApplyingFilters: Bool = false
  @State private var currentSort: CatalogSort = .titleAZ
  
  // MARK: - Account & Logo State
  
  @StateObject private var logoObserver = CatalogLogoObserver()
  @State private var currentAccountUUID: String = AccountsManager.shared.currentAccount?.uuid ?? ""
  
  // MARK: - Initialization
  
  init(title: String = "", url: URL) {
    self.title = title
    self.url = url
  }

  // MARK: - Main View

  var body: some View {
    VStack(spacing: 0) {
      toolbarSection
      contentSection
    }
    .overlay(alignment: .bottom) { SamplePreviewBarView() }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) {
        LibraryNavTitleView(onTap: { openLibraryHome() })
          .id(logoObserver.token.uuidString + currentAccountUUID)
      }
      ToolbarItem(placement: .navigationBarTrailing) {
        if showSearch {
          Button(action: { dismissSearch() }) {
            Text(Strings.Generic.cancel)
          }
        } else {
          Button(action: { presentSearch() }) {
            ImageProviders.MyBooksView.search
          }
        }
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
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ToggleSampleNotification")).receive(on: RunLoop.main)) { note in
      guard let info = note.userInfo as? [String: Any], let identifier = info["bookIdentifier"] as? String else { return }
      let action = (info["action"] as? String) ?? "toggle"
      if action == "close" {
        SamplePreviewManager.shared.close()
        return
      }
      if let book = TPPBookRegistry.shared.book(forIdentifier: identifier) ?? (lanes.flatMap { $0.books } + ungroupedBooks).first(where: { $0.identifier == identifier }) {
        SamplePreviewManager.shared.toggle(for: book)
      }
    }
    .onDisappear { SamplePreviewManager.shared.close() }
    // Avoid broad reloads; rely on targeted state changes and progress updates
    .onReceive(
      NotificationCenter.default
        .publisher(for: .TPPBookRegistryStateDidChange)
        .throttle(for: .milliseconds(350), scheduler: RunLoop.main, latest: true)
    ) { note in
      let changedId = (note.userInfo as? [String: Any])?["bookIdentifier"] as? String
      applyRegistryUpdates(changedIdentifier: changedId)
    }
    // Prefer targeted updates using the download progress publisher to avoid rebuilding all lanes per tick
    .onReceive(MyBooksDownloadCenter.shared.downloadProgressPublisher
      .throttle(for: .milliseconds(350), scheduler: RunLoop.main, latest: true)
      .map { $0.0 }
      .removeDuplicates()) { changedId in
        applyRegistryUpdates(changedIdentifier: changedId)
      }
    .onChange(of: showingFiltersSheet) { presented in
      guard presented else { return }
      // Set up pending selections based on current applied state
      // Don't reset until user actually applies - preserve existing filtering if they cancel
      if !appliedSelections.isEmpty {
        pendingSelections = reconstructSelectionsFromCurrentFacets()
      } else {
        pendingSelections = []
      }
    }
    .onChange(of: currentSort) { _ in
      sortBooksInPlace()
      saveFilterState()
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
    
    if let savedState = coordinator.resolveCatalogFilterState(for: url) {
      restoreFilterState(savedState)
      if !appliedSelections.isEmpty {
        await applySingleFilters()
      } else {
        await fetchAndApplyFeed(at: url)
      }
    } else {
      await fetchAndApplyFeed(at: url)
    }
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
          case .acquisitionUngrouped:
            ungroupedBooks = entries.compactMap { CatalogViewModel.makeBook(from: $0) }
            facetGroups = CatalogViewModel.extractFacets(from: feedObjc).0
            appliedSelections = Set(
              selectionKeysFromActiveFacets(includeDefaults: false)
                .compactMap(parseKey)
                .map { makeGroupTitleKey(group: $0.group, title: $0.title) }
            )
            sortBooksInPlace()
            saveFilterState()
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

  /// Refresh visible books with updated metadata so button states reflect current status.
  /// Only update items that actually changed to keep identity stable and avoid flicker.
  private func applyRegistryUpdates(changedIdentifier: String?) {
    if !lanes.isEmpty {
      var newLanes = lanes
      for idx in newLanes.indices {
        var books = newLanes[idx].books
        var changed = false
        for bIdx in books.indices {
          let book = books[bIdx]
          if let changedIdentifier, book.identifier != changedIdentifier { continue }
          let updated = TPPBookRegistry.shared.updatedBookMetadata(book) ?? book
          if updated != book {
            books[bIdx] = updated
            changed = true
          }
        }
        if changed { newLanes[idx] = CatalogLaneModel(title: newLanes[idx].title, books: books, moreURL: newLanes[idx].moreURL) }
      }
      lanes = newLanes
    }

    if !ungroupedBooks.isEmpty {
      var books = ungroupedBooks
      var anyChanged = false
      for idx in books.indices {
        let book = books[idx]
        if let changedIdentifier, book.identifier != changedIdentifier { continue }
        let updated = TPPBookRegistry.shared.updatedBookMetadata(book) ?? book
        if updated != book { books[idx] = updated; anyChanged = true }
      }
      if anyChanged { ungroupedBooks = books }
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

  private func presentLaneMore(title: String, url: URL) {
    if NavigationCoordinatorHub.shared.coordinator == nil {
      NavigationCoordinatorHub.shared.coordinator = coordinator
    }
    coordinator.push(.catalogLaneMore(title: title, url: url))
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
      onApply: { Task { await applySingleFilters() } },
      onCancel: { showingFiltersSheet = false },
      isApplying: isApplyingFilters
    )
  }

  // MARK: - Single Filter Handling

  @MainActor
  private func applySingleFilters() async {
    let specificFilters: [ParsedKey] = pendingSelections
      .compactMap { selection in
        guard let parsed = parseKey(selection) else { return nil }
        return parsed.isDefaultTitle ? nil : parsed
      }

    if specificFilters.isEmpty {
      await fetchAndApplyFeed(at: url)
      appliedSelections = []
      showingFiltersSheet = false
      return
    }

    isApplyingFilters = true
    error = nil
    defer {
      isApplyingFilters = false
      showingFiltersSheet = false
    }

    do {
      let client = URLSessionNetworkClient()
      let parser = OPDSParser()
      let api = DefaultCatalogAPI(client: client, parser: parser)

      // FRESH START: Reset to original feed and rebuild filter sequence completely
      await fetchAndApplyFeed(at: url)  // This gives us clean facet groups
      var currentFacetGroups = facetGroups
      
      // Sort filters by priority for consistent application order
      let sortedFilters = specificFilters.sorted { filter1, filter2 in
        let priority1 = getGroupPriority(filter1.group)
        let priority2 = getGroupPriority(filter2.group)
        return priority1 < priority2
      }
      
      // Apply each filter sequentially, starting fresh each time
      for filter in sortedFilters {
        // Find the filter in the current facet groups
        if let filterURL = findFilterInCurrentFacets(filter, in: currentFacetGroups) {
          if let feed = try await api.fetchFeed(at: filterURL) {
            // Update books and facets with this filter's results
          if let entries = feed.opdsFeed.entries as? [TPPOPDSEntry] {
            ungroupedBooks = entries.compactMap { CatalogViewModel.makeBook(from: $0) }
            sortBooksInPlace()
          }
            
            // Update facet groups for next filter (preserves current filter state)
          if feed.opdsFeed.type == TPPOPDSFeedType.acquisitionUngrouped {
              currentFacetGroups = CatalogViewModel.extractFacets(from: feed.opdsFeed).0
            }
          }
        }
      }

      facetGroups = currentFacetGroups
      appliedSelections = Set(
        specificFilters.map { makeGroupTitleKey(group: $0.group, title: $0.title) }
      )
      
      saveFilterState()

    } catch {
      self.error = error.localizedDescription
    }
  }
  
  
  /// Reconstruct pending selections from applied selections using current facets
  private func reconstructSelectionsFromCurrentFacets() -> Set<String> {
    var reconstructed: Set<String> = []
    
    for appliedSelection in appliedSelections {
      let parts = appliedSelection.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
      guard parts.count >= 2 else { continue }
      
      let groupName = parts[0]
      let title = parts[1]
      
      // Find this filter in the fresh facet groups
      for group in facetGroups where group.name == groupName {
        for filter in group.filters where filter.title == title {
          let key = makeKey(group: group.name, title: filter.title, hrefString: filter.href?.absoluteString ?? "")
          reconstructed.insert(key)
          break
        }
      }
    }
    
    return reconstructed
  }
  
  /// Find a specific filter in the current facet groups (simplified approach)
  private func findFilterInCurrentFacets(_ filter: ParsedKey, in currentFacetGroups: [CatalogFilterGroup]) -> URL? {
    for group in currentFacetGroups {
      // Match by group name
      if group.name.lowercased() == filter.group.lowercased() {
        for facet in group.filters {
          // Match by filter title
          if facet.title.lowercased() == filter.title.lowercased() {
            return facet.href
          }
        }
      }
    }
    return nil
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

  internal struct ParsedKey {
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

  internal func parseKey(_ key: String) -> ParsedKey? {
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
      // Don't automatically add "All" filters - let the UI handle defaults
      // This prevents "All" filters from being re-added when reopening filter sheet
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
    appliedSelections.filter { groupTitleKey in
      // appliedSelections contains group|title keys, need to check if title is default
      let parts = groupTitleKey.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
      guard parts.count >= 2 else { return false }
      let title = parts[1]
      let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let isDefaultTitle = t == "all" || t == "all formats" || t == "all collections" || t == "all distributors"
      return !isDefaultTitle  // Exclude "All" filters from count
    }.count
  }
  
  /// Groups selected filters by their facet groups in priority order for proper chaining
  /// Returns [(groupName, [URL])] sorted by group priority
  private func groupSelectedFiltersByFacetGroup(_ facetURLs: [URL], currentFacetGroups: [CatalogFilterGroup]) -> [(String, [URL])] {
    var filtersByGroup: [String: [URL]] = [:]
    
    for url in facetURLs {
      if let groupName = findFacetGroupName(for: url, in: currentFacetGroups) {
        filtersByGroup[groupName, default: []].append(url)
      } else {
        // Fallback: categorize by URL content if no group found
        let category = categorizeFacetURL(url)
        filtersByGroup[category, default: []].append(url)
      }
    }
    
    // Sort groups by priority (Collection first, then others)
    return filtersByGroup.sorted { (group1, group2) in
      let priority1 = getGroupPriority(group1.key)
      let priority2 = getGroupPriority(group2.key)
      return priority1 < priority2
    }
  }
  
  /// Prioritizes selected filters for sequential application (additive OPDS 1.2 style)
  /// Returns filters in order they should be applied, with each building on the previous
  internal func prioritizeSelectedFilters(_ facetURLs: [URL], currentFacetGroups: [CatalogFilterGroup]) -> [URL] {
    // Group filters by their facet group, then prioritize groups
    var filtersByGroup: [String: [URL]] = [:]
    
    for url in facetURLs {
      if let groupName = findFacetGroupName(for: url, in: currentFacetGroups) {
        filtersByGroup[groupName, default: []].append(url)
      } else {
        // Fallback: categorize by URL content if no group found
        let category = categorizeFacetURL(url)
        filtersByGroup[category, default: []].append(url)
      }
    }
    
    // Sort groups by priority, then return one filter per group in priority order
    let sortedGroups = filtersByGroup.sorted { (group1, group2) in
      let priority1 = getGroupPriority(group1.key)
      let priority2 = getGroupPriority(group2.key)
      return priority1 < priority2
    }
    
    // Take the first (or only) filter from each group
    // In OPDS 1.2, you can only have one active filter per group anyway
    return sortedGroups.compactMap { $0.value.first }
  }
  
  /// Groups facet URLs by their type/group for sequential application
  private func groupFacetsByType(_ facetURLs: [URL], currentFacetGroups: [CatalogFilterGroup]) -> [(String, [URL])] {
    var groupedFacets: [String: [URL]] = [:]
    
    for url in facetURLs {
      if let groupName = findFacetGroupName(for: url, in: currentFacetGroups) {
        groupedFacets[groupName, default: []].append(url)
      } else {
        // Fallback: categorize by URL content if no group found
        let category = categorizeFacetURL(url)
        groupedFacets[category, default: []].append(url)
      }
    }
    
    // Sort groups by priority
    return groupedFacets.sorted { (group1, group2) in
      let priority1 = getGroupPriority(group1.key)
      let priority2 = getGroupPriority(group2.key)
      return priority1 < priority2
    }
  }
  
  /// Finds the group name for a facet URL by matching it against current facet groups
  internal func findFacetGroupName(for url: URL, in facetGroups: [CatalogFilterGroup]) -> String? {
    for group in facetGroups {
      for filter in group.filters {
        if filter.href?.absoluteString == url.absoluteString {
          return group.name
        }
      }
    }
    return nil
  }
  
  /// Categorizes a facet URL when no group is found
  internal func categorizeFacetURL(_ url: URL) -> String {
    let urlString = url.absoluteString.lowercased()
    let queryString = url.query?.lowercased() ?? ""
    
    if urlString.contains("collection") || urlString.contains("library") {
      return "Collection"
    } else if urlString.contains("format") || urlString.contains("media") {
      return "Format"
    } else if urlString.contains("availability") || urlString.contains("available") {
      return "Availability"
    } else if urlString.contains("language") || urlString.contains("lang") {
      return "Language"
    } else if urlString.contains("subject") || urlString.contains("genre") {
      return "Subject"
    } else {
      return "Other"
    }
  }
  
  /// Gets priority for group ordering
  internal func getGroupPriority(_ groupName: String) -> Int {
    let name = groupName.lowercased()
    // Collection Name should be applied first (most restrictive)
    if name.contains("collection") || name.contains("library") { return 1 }
    // Distributor comes next
    if name.contains("distributor") { return 2 }
    // Format filters
    if name.contains("format") || name.contains("media") { return 3 }
    // Availability filters
    if name.contains("availability") || name.contains("available") { return 4 }
    // Language filters
    if name.contains("language") || name.contains("lang") { return 5 }
    // Subject/Genre filters
    if name.contains("subject") || name.contains("genre") { return 6 }
    return 10
  }
  
  /// Finds the equivalent facet URL in the current (updated) facet groups
  /// This ensures we use the server's updated links that preserve previous filter state
  private func findEquivalentFacetURL(originalURL: URL, in currentFacetGroups: [CatalogFilterGroup]) -> URL? {
    // Extract the filter title from the original URL to find the equivalent facet
    let originalKey = makeKeyFromURL(originalURL)
    guard let originalParsed = parseKey(originalKey) else { 
      return originalURL 
    }
    
    // Find the facet group that matches
    for group in currentFacetGroups {
      // Match by group name (case insensitive)
      let groupMatches = group.name.lowercased().contains(originalParsed.group.lowercased()) ||
                        originalParsed.group.lowercased().contains(group.name.lowercased()) ||
                        group.id.lowercased() == originalParsed.group.lowercased()
      
      if groupMatches {
        for filter in group.filters {
          // Match by filter title (case insensitive)
          if filter.title.lowercased() == originalParsed.title.lowercased() {
            return filter.href
          }
        }
      }
    }
    return originalURL
  }
  
  /// Finds the best facet URL to apply from the current facet groups
  /// This is key: it looks for the equivalent facet in the updated facet groups
  private func findBestFacetURL(for originalURLs: [URL], in currentFacetGroups: [CatalogFilterGroup]) -> URL? {
    // Try to find a matching facet in the current (updated) facet groups
    for originalURL in originalURLs {
      // First, try exact match
      for group in currentFacetGroups {
        for filter in group.filters {
          if let filterURL = filter.href, filterURL.absoluteString == originalURL.absoluteString {
            return filterURL
          }
        }
      }
      
      // If no exact match, try to find a similar facet by title/content
      if let parsedOriginal = parseKey(makeKeyFromURL(originalURL)) {
        for group in currentFacetGroups {
          for filter in group.filters {
            if filter.title.lowercased() == parsedOriginal.title.lowercased() {
              return filter.href
            }
          }
        }
      }
    }
    
    // Fallback: return the first original URL if no match found in current facets
    return originalURLs.first
  }
  
  /// Helper to create a key from URL for parsing
  private func makeKeyFromURL(_ url: URL) -> String {
    // Extract meaningful parts from URL query parameters to create a parseable key
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
          let queryItems = components.queryItems else {
      return "unknown|unknown|\(url.absoluteString)"
    }
    
    // Look for known facet parameters to determine group and title
    var group = "unknown"
    var title = "unknown"
    
    for item in queryItems {
      switch item.name.lowercased() {
      case "collectionname":
        group = "Collection Name"
        title = item.value?.replacingOccurrences(of: "+", with: " ") ?? "unknown"
      case "distributor":
        group = "Distributor"  
        title = item.value?.replacingOccurrences(of: "+", with: " ") ?? "unknown"
      case "available":
        group = "Availability"
        title = item.value == "now" ? "Available now" : 
                item.value == "always" ? "Yours to keep" : 
                item.value ?? "unknown"
      case "format":
        group = "Format"
        title = item.value?.uppercased() ?? "unknown"
      case "subject", "genre":
        group = "Subject"
        title = item.value?.replacingOccurrences(of: "+", with: " ") ?? "unknown"
      default:
        continue
      }
    }
    
    return "\(group)|\(title)|\(url.absoluteString)"
  }
  
  /// Prioritizes facet URLs to ensure consistent application order
  /// Priority order: Collection/Library -> Format -> Availability -> Language -> Other
  private func prioritizeFacetURLs(_ facetURLs: [URL]) -> [URL] {
    return facetURLs.sorted { url1, url2 in
      let priority1 = getFacetPriority(url1)
      let priority2 = getFacetPriority(url2)
      
      if priority1 != priority2 {
        return priority1 < priority2  // Lower number = higher priority
      }
      
      // If same priority, sort alphabetically for consistency
      return url1.absoluteString < url2.absoluteString
    }
  }
  
  /// Determines the priority of a facet based on its URL or content
  /// Lower numbers = higher priority (applied first)
  private func getFacetPriority(_ url: URL) -> Int {
    let urlString = url.absoluteString.lowercased()
    let queryString = url.query?.lowercased() ?? ""
    
    // Collection/Library filters should be applied first (broadest filter)
    if urlString.contains("collection") || urlString.contains("library") || 
       queryString.contains("collection") || queryString.contains("library") {
      return 1
    }
    
    // Format filters (epub, pdf, audiobook, etc.)
    if urlString.contains("format") || urlString.contains("media") ||
       queryString.contains("format") || queryString.contains("media") ||
       urlString.contains("epub") || urlString.contains("pdf") || urlString.contains("audiobook") {
      return 2
    }
    
    // Availability filters (available, checked out, etc.)
    if urlString.contains("availability") || urlString.contains("available") ||
       queryString.contains("availability") || queryString.contains("available") {
      return 3
    }
    
    // Language filters
    if urlString.contains("language") || urlString.contains("lang") ||
       queryString.contains("language") || queryString.contains("lang") {
      return 4
    }
    
    // Subject/Genre filters
    if urlString.contains("subject") || urlString.contains("genre") ||
       queryString.contains("subject") || queryString.contains("genre") {
      return 5
    }
    
    // All other filters get lowest priority (applied last for fine-tuning)
    return 10
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
  
  // MARK: - Search Functionality
  
  @ViewBuilder
  private var searchSection: some View {
    CatalogSearchView(
      repository: CatalogRepository(api: DefaultCatalogAPI(client: URLSessionNetworkClient(), parser: OPDSParser())),
      baseURL: { url }, // Use the lane's URL as the search base to scope search to this lane
      books: allBooks,
      onBookSelected: presentBookDetail
    )
  }
  
  private var allBooks: [TPPBook] {
    if !lanes.isEmpty {
      return lanes.flatMap { $0.books }
    }
    return ungroupedBooks
  }
  
  private func presentSearch() {
    withAnimation { showSearch = true }
  }
  
  private func dismissSearch() {
    withAnimation { showSearch = false }
  }
}

// MARK: - View Sections

private extension CatalogLaneMoreView {
  
  @ViewBuilder
  var toolbarSection: some View {
    if showSearch {
      searchToolbar
    } else if !facetGroups.isEmpty {
      filterToolbar
    }
  }
  
  @ViewBuilder
  var searchToolbar: some View {
    // Search toolbar would go here
    EmptyView()
  }
  
  @ViewBuilder
  var filterToolbar: some View {
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
        loadingIndicator
      }
    }
    
    Divider()
  }
  
  @ViewBuilder
  var loadingIndicator: some View {
    HStack(spacing: 6) {
      ProgressView()
        .progressViewStyle(CircularProgressViewStyle(tint: .primary))
        .scaleEffect(0.8)
      if isApplyingFilters {
        Text("Filtering...")
          .palaceFont(size: 12)
          .foregroundColor(.secondary)
      }
    }
    .padding(.trailing, 12)
  }
  
  @ViewBuilder
  var contentSection: some View {
    if showSearch {
      searchSection
    } else if isLoading {
      loadingView
    } else if let error = error {
      errorView(error)
    } else if !lanes.isEmpty {
      lanesView
    } else {
      booksView
    }
  }
  
  @ViewBuilder
  var loadingView: some View {
    ScrollView {
      BookListSkeletonView()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  
  func errorView(_ errorMessage: String) -> some View {
    Text(errorMessage)
      .padding()
  }
  
  @ViewBuilder
  var lanesView: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        ForEach(lanes) { lane in
          CatalogLaneRowView(
            title: lane.title,
            books: lane.books,
            moreURL: lane.moreURL,
            onSelect: presentBookDetail,
            onMoreTapped: { title, url in
              presentLaneMore(title: title, url: url)
            },
            showHeader: true
          )
        }
      }
      .padding(.vertical, 12)
    }
    .refreshable { await fetchAndApplyFeed(at: url) }
  }
  
  @ViewBuilder
  var booksView: some View {
    ScrollView {
      BookListView(books: ungroupedBooks, isLoading: $isLoading) { book in
        presentBookDetail(book)
      }
    }
    .refreshable { await fetchAndApplyFeed(at: url) }
  }
  
  // MARK: - Filter State Persistence
  
  private func saveFilterState() {
    let sortString = currentSort.localizedString
    let state = CatalogLaneFilterState(
      appliedSelections: appliedSelections,
      currentSort: sortString,
      facetGroups: facetGroups
    )
    coordinator.storeCatalogFilterState(state, for: url)
  }
  
  private func restoreFilterState(_ state: CatalogLaneFilterState) {
    appliedSelections = state.appliedSelections
    facetGroups = state.facetGroups
    
    // Convert string back to enum
    if let restoredSort = CatalogSort.allCases.first(where: { $0.localizedString == state.currentSort }) {
      currentSort = restoredSort
    }
  }
}
