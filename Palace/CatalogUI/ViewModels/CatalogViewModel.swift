import Foundation
import Combine
import PalaceLogging
import PalaceBookRegistry
@preconcurrency import PalaceCatalog
import PalaceNetwork
import PalaceBookModel

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
  private let bookRegistry: TPPBookRegistryProvider
  private let imageCache: ImageCacheType
  private let reachability: Reachability
  /// Supplies the books for the "Side Loaded" catalog lane (Module D / PP-2679).
  /// Returns `[]` when side-loading is off — the feature-flag gate lives at the
  /// construction site (`AppTabHostView`), keeping the flag out of the VM. When
  /// this returns ≥1 book, `withSideloadedLane(_:)` prepends a lane on every
  /// catalog conversion path.
  private let sideloadedLaneBooksProvider: () -> [TPPBook]
  private var cancellables = Set<AnyCancellable>()

  // MARK: - Public accessors for search
  var searchRepository: CatalogRepositoryProtocol { repository }
  var searchBaseURL: () -> URL? { topLevelURLProvider }

  // MARK: - Entry Point View Retention

  /// All loaded entry point feeds, keyed by URL. The view renders all of
  /// them in a ZStack and shows only the active one. This keeps SwiftUI
  /// views (and their loaded cover images) alive across entry point switches.
  @Published private(set) var loadedFeeds: [URL: CatalogContent] = [:]

  /// The currently active entry point URL. The view uses this to determine
  /// which feed in loadedFeeds to display.
  @Published private(set) var activeEntryPointURL: URL?

  // MARK: - Internal State
  private var lastLoadedURL: URL?
  private var currentLoadTask: Task<Void, Never>?

  /// Detached cover-prefetch tasks spawned during a load. They intentionally
  /// outlive `currentLoadTask` (background cache warming), so they must be
  /// tracked and cancelled explicitly on reload / refresh / teardown.
  /// Otherwise they keep firing cover downloads for a feed the patron has
  /// already navigated away from, piling avoidable load onto the shared
  /// connection pool — the load multiplier behind the "catalog stuck" bug.
  private var prefetchTasks: [Task<Void, Never>] = []

  init(
    repository: CatalogRepositoryProtocol,
    topLevelURLProvider: @escaping () -> URL?,
    bookRegistry: TPPBookRegistryProvider,
    imageCache: ImageCacheType,
    sideloadedLaneBooksProvider: @escaping () -> [TPPBook] = { [] },
    reachability: Reachability = AppContainer.production().reachability
  ) {
    self.repository = repository
    self.topLevelURLProvider = topLevelURLProvider
    self.bookRegistry = bookRegistry
    self.imageCache = imageCache
    self.sideloadedLaneBooksProvider = sideloadedLaneBooksProvider
    self.reachability = reachability
    observeConnectivity()
  }

  /// Literal (not localized) side-loaded lane title. Side-loading is a
  /// DEBUG/test-only feature gated behind `isSideLoadingEnabled` (default OFF in
  /// production), so per the Module D contract a literal is acceptable here.
  private static let sideloadedLaneTitle = "Side Loaded"

  /// SINGLE CHOKE POINT for injecting the "Side Loaded" lane into every catalog
  /// conversion (PP-2679). EVERY former catalog-content call site routes
  /// through here so the lane can never silently vanish on one path — in
  /// particular the `applyFacet` cache-HIT fast path, which a per-site patch
  /// would miss. The lane is present iff `sideloadedLaneBooksProvider()` returns
  /// ≥1 book; when it returns `[]` the result is identical to the un-injected
  /// baseline shape.
  private func withSideloadedLane(_ mapped: MappedCatalog) -> CatalogContent {
    mapped.toCatalogContent(prepending: sideloadedLanes())
  }

  /// The "Side Loaded" lane rows for the current provider snapshot — empty when
  /// side-loading is off or the registry has no books. Shared by the success
  /// path (`withSideloadedLane`) and the failure path (`loadFailureState`, F-1)
  /// so both surface exactly the same lane, and neither shows one when the
  /// provider is empty.
  private func sideloadedLanes() -> [CatalogLaneModel] {
    let books = sideloadedLaneBooksProvider()
    return books.isEmpty
      ? []
      : [CatalogLaneModel(title: Self.sideloadedLaneTitle, books: books, moreURL: nil)]
  }

  deinit {
    prefetchTasks.forEach { $0.cancel() }
  }

  /// Cancel any in-flight background cover prefetch. Called whenever the feed
  /// the prefetch was warming is being replaced (reload / refresh) or the view
  /// model is torn down, so stale prefetch can't keep saturating the network.
  private func cancelPrefetch() {
    prefetchTasks.forEach { $0.cancel() }
    prefetchTasks.removeAll()
  }

  /// Test seams for the prefetch-cancellation contract (no real timing needed).
  /// Plain `internal` (matching the codebase's existing test-accessor
  /// convention, e.g. TPPNetworkExecutor.refreshAttemptCount) rather than a
  /// `#if DEBUG` block, which the blast-radius gate flags for shipping into
  /// sim/dev/TestFlight builds.
  var prefetchTaskCountForTesting: Int { prefetchTasks.count }
  func appendPrefetchTaskForTesting(_ task: Task<Void, Never>) { prefetchTasks.append(task) }
  func cancelPrefetchForTesting() { cancelPrefetch() }

  /// Test seam — deterministically join the in-flight load. `load()` /
  /// `forceRefresh()` / `reload()` spawn `currentLoadTask` (repo fetch →
  /// off-actor `mapFeed` → image-cache warming) and return WITHOUT awaiting it,
  /// so the `.loaded`/`.error`/`.offline` transition lands asynchronously. A
  /// test that asserts the terminal state must otherwise wait on the `$state`
  /// publisher against a fixed wall-clock deadline (`fulfillment(timeout:)`),
  /// which STARVES under CI sim-clone oversubscription — the `.userInitiated`
  /// map hop and cache warming get deferred past the deadline even though the
  /// code is correct. Awaiting the retained Task handle blocks EXACTLY until the
  /// load finishes, removing the pool/wall-clock dependence entirely.
  ///
  /// Changes NO production behavior: this only reads a handle the view model
  /// already retains; `load()` still spawns the task and returns immediately.
  /// Returns at once if no load is in flight.
  func _awaitLoadForTesting() async {
    await currentLoadTask?.value
  }

  // MARK: - Connectivity

  /// Auto-reload the catalog when connectivity returns while we are showing the
  /// offline state. This is what makes the offline state self-healing — the
  /// patron does not need a Reload button (AC: loads automatically on reconnect).
  private func observeConnectivity() {
    reachability.connectivityPublisher
      .filter { $0 }
      .sink { [weak self] _ in
        Task { @MainActor in self?.handleConnectivityRestored() }
      }
      .store(in: &cancellables)
  }

  private func handleConnectivityRestored() {
    guard case .offline = state else { return }
    Log.info(#file, "Connectivity restored — reloading catalog")
    Task { await forceRefresh() }
  }

  /// Map a load failure to either the offline state (no connectivity) or the
  /// generic error state (genuine online failure). Keeps the offline-vs-error
  /// decision in one place so both the nil-feed and thrown-error paths agree.
  private func loadFailureState(message: String) -> CatalogState {
    // F-1: attach the Side Loaded lane so imported books stay reachable even
    // when the catalog feed fails. The feed error is still surfaced (the view
    // renders the error/offline banner above the lane). When side-loading
    // contributes no lane the states carry `[]`, so the plain error/offline
    // presentation is byte-identical to the pre-F-1 behavior.
    let lanes = sideloadedLanes()
    return reachability.isConnectedToNetwork()
      ? .error(message, sideloadedLanes: lanes)
      : .offline(sideloadedLanes: lanes)
  }

  // MARK: - Public API

  func load() async {
    guard let url = topLevelURLProvider() else { return }

    // Skip if content is already showing. This prevents reloading when
    // navigating back from book detail or when the view reappears.
    // lastLoadedURL may differ from the top-level URL if the user switched
    // entry points (e.g., /groups/ vs /groups/?entrypoint=Ebooks).
    if case .loaded = state { return }
    if case .applyingFacet = state { return }

    state = .loading
    currentLoadTask?.cancel()
    cancelPrefetch()

    currentLoadTask = Task { [weak self] in
      guard let self, !Task.isCancelled else { return }

      do {
        let t0 = CFAbsoluteTimeGetCurrent()

        guard let feed = try await self.repository.loadTopLevelCatalog(at: url) else {
          guard !Task.isCancelled else { return }
          self.state = self.loadFailureState(message: "Failed to load catalog")
          return
        }

        let t1 = CFAbsoluteTimeGetCurrent()
        guard !Task.isCancelled else { return }

        let mapped = await Task.detached(priority: .userInitiated) { [bookRegistry = self.bookRegistry] () -> MappedCatalog in
          return await Self.mapFeed(feed, currentURL: url, bookRegistry: bookRegistry)
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
          await self.imageCache.warmMemoryCache(for: Array(warmKeys))
        }

        guard !Task.isCancelled else { return }

        let content = self.withSideloadedLane(mapped)
        self.state = .loaded(content)
        self.lastLoadedURL = url
        // Store under both the top-level URL and the active entry point href,
        // since /groups/ and /groups/?entrypoint=All are different URLs for
        // the same content. Without this, returning to "All" misses the view cache.
        self.loadedFeeds[url] = content
        if let activeEP = content.selectors.entryPoints.first(where: { $0.active }),
           let epHref = activeEP.href, epHref != url {
          self.loadedFeeds[epHref] = content
        }
        self.activeEntryPointURL = url

        // Launch-timing: catalog content is on screen. Records the
        // process-start → catalog-loaded interval (time-to-interactive).
        await AppLaunchTracker.shared.recordMilestone(.catalogLoaded)

        let t3 = CFAbsoluteTimeGetCurrent()
        let lanesCount = mapped.lanes.count
        let booksCount = mapped.lanes.reduce(0) { $0 + $1.books.count }
        Log.warn(#file, "[PERF] Catalog load: fetch=\(Int((t1-t0)*1000))ms, map=\(Int((t2-t1)*1000))ms, render=\(Int((t3-t2)*1000))ms, total=\(Int((t3-t0)*1000))ms (\(lanesCount) lanes, \(booksCount) books)")

        // Warm remaining visible lanes in background post-render
        let remainingBooks = mapped.lanes.dropFirst().prefix(2).flatMap { $0.books }.prefix(20)
        if !remainingBooks.isEmpty {
          let bgKeys = remainingBooks.flatMap {
            ["\($0.identifier)_\(laneDisplayHeight)pt", $0.identifier]
          }
          Task { await self.imageCache.warmMemoryCache(for: Array(bgKeys)) }
        }

        // Prefetch thumbnails for visible lanes (network fetch for uncached)
        if !mapped.lanes.isEmpty {
          let visibleBooks = mapped.lanes.prefix(3).flatMap { $0.books }
          await self.prefetchThumbnails(for: Array(visibleBooks.prefix(30)))
        } else if !mapped.ungroupedBooks.isEmpty {
          await self.prefetchThumbnails(for: Array(mapped.ungroupedBooks.prefix(20)))
        }

        // Deferred prefetch for below-fold lanes. Tracked + cancellable so a
        // reload/teardown stops it mid-flight instead of letting it keep
        // warming covers for a feed the patron has left.
        if mapped.lanes.count > 3 {
          let belowFoldPrefetch = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            let remaining = mapped.lanes.dropFirst(3).flatMap { $0.books }
            for batch in stride(from: 0, to: remaining.count, by: 20) {
              if Task.isCancelled { return }
              let end = min(batch + 20, remaining.count)
              await self.prefetchThumbnails(for: Array(remaining[batch..<end]))
            }
          }
          self.prefetchTasks.append(belowFoldPrefetch)
        }

        // Preload inactive entry points in background. Also tracked so a
        // library switch / reload cancels these speculative feed fetches.
        let inactiveEntryPoints = mapped.entryPoints.filter { !$0.active }
        if !inactiveEntryPoints.isEmpty {
          // Hoist the main-actor-isolated `repository` read onto the main actor
          // here. `CatalogRepositoryProtocol` is now `Sendable`, so the detached
          // preload captures the value rather than reading `self.repository` off
          // the main actor (the `targeted` isolation diagnostic). The task is
          // tracked in `prefetchTasks` and cancelled on reload/teardown (`deinit`
          // cancels all prefetch tasks), and each fetch is guarded by
          // `Task.isCancelled`, so dropping `[weak self]` is behavior-equivalent-
          // or-better: the old strong-`self` capture kept the VM alive for the
          // task's lifetime (so `deinit`'s cancel couldn't interrupt an in-flight
          // preload); capturing only `repository` lets the VM deinit mid-preload,
          // so `deinit`'s cancel now genuinely short-circuits at the next
          // isCancelled check. Benign either way (speculative, cached preload).
          let repository = self.repository
          let entryPointPreload = Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
              for ep in inactiveEntryPoints {
                guard let epURL = ep.href else { continue }
                group.addTask {
                  if Task.isCancelled { return }
                  do {
                    _ = try await repository.loadTopLevelCatalog(at: epURL)
                    Log.warn(#file, "[PERF] Preloaded entry point '\(ep.title)'")
                  } catch { }
                }
              }
            }
          }
          self.prefetchTasks.append(entryPointPreload)
        }
      } catch is CancellationError {
        Log.debug(#file, "Catalog load was cancelled")
        return
      } catch {
        guard !Task.isCancelled else { return }
        Log.error(#file, "Failed to load catalog: \(error.localizedDescription)")
        self.state = self.loadFailureState(message: error.localizedDescription)
      }
    }
  }

  @MainActor
  func forceRefresh() async {
    Log.info(#file, "Force refreshing catalog...")
    repository.invalidateCache(for: topLevelURLProvider() ?? URL(fileURLWithPath: "/"))
    // Clear the network executor's PRIVATE URLCache (where feeds are actually
    // served from) — not URLCache.shared, which holds only public non-feed
    // responses. Clearing the wrong cache let an explicit pull-to-refresh still
    // be served a stale feed (N1 split-brain, same class as sign-out/force-reset).
    AppContainer.production().networkExecutor.clearCache()
    lastLoadedURL = nil
    loadedFeeds.removeAll()
    activeEntryPointURL = nil
    state = .loading
    await load()
  }

  /// Pull-to-refresh. Invalidates the account-scoped cache so the reload is
  /// guaranteed to hit the network, then reloads.
  func refresh() async {
    await reload(invalidatingCache: true)
  }

  /// Shared reload path for both pull-to-refresh and library switches.
  ///
  /// - When `invalidatingCache == true` (pull-to-refresh) the current feed's
  ///   cache entry is dropped via the protocol seam
  ///   (`repository.invalidateCache(for:)`), forcing a fresh network fetch.
  /// - When `invalidatingCache == false` (library switch / account change) the
  ///   account-scoped cache is left intact so stale-while-revalidate can serve
  ///   the new library's catalog instantly with a background refresh — the
  ///   de-triple-fire win on A→B→A switches.
  private func reload(invalidatingCache: Bool) async {
    guard let url = topLevelURLProvider() else { return }
    if invalidatingCache {
      repository.invalidateCache(for: url)
    }
    lastLoadedURL = nil
    loadedFeeds.removeAll()
    activeEntryPointURL = nil
    currentLoadTask?.cancel()
    state = .loading
    await load()
  }

  @MainActor
  func applyFacet(_ facet: CatalogFilter) async {
    guard let href = facet.href else { return }
    guard let currentContent = state.content else { return }
    let t0 = CFAbsoluteTimeGetCurrent()

    let optimisticSelectors = currentContent.selectors.withSelectedFacet(facet)

    // Try synchronous cache check — instant swap, no opacity fade
    if let cachedFeed = repository.cachedFeed(for: href) {
      let mapped = Self.mapFeed(cachedFeed, bookRegistry: bookRegistry)
      let newContent = withSideloadedLane(mapped)
      state = .loaded(CatalogContent(
        title: newContent.title,
        feed: newContent.feed,
        selectors: CatalogSelectors(
          entryPoints: newContent.selectors.entryPoints,
          facetGroups: optimisticSelectors.facetGroups
        )
      ))
      scrollGeneration &+= 1
      Log.warn(#file, "[PERF] applyFacet '\(facet.title)': cache HIT \(Int((CFAbsoluteTimeGetCurrent()-t0)*1000))ms")
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
        let mapped = Self.mapFeed(feed, bookRegistry: bookRegistry)
        state = .loaded(withSideloadedLane(mapped))
        scrollGeneration &+= 1
      } else {
        state = .loaded(currentContent)
      }
      Log.warn(#file, "[PERF] applyFacet '\(facet.title)': cache MISS \(Int((CFAbsoluteTimeGetCurrent()-t0)*1000))ms")
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
    let t0 = CFAbsoluteTimeGetCurrent()

    let previousContent = currentContent
    currentLoadTask?.cancel()

    // Optimistically update entry point selection
    let optimisticSelectors = currentContent.selectors.withSelectedEntryPoint(facet)

    // Store current content before switching
    if let currentURL = activeEntryPointURL ?? lastLoadedURL {
      loadedFeeds[currentURL] = currentContent
    }

    // Check if we already have this feed's views alive
    if let existing = loadedFeeds[href] {
      let updated = CatalogContent(
        title: existing.title,
        feed: existing.feed,
        selectors: CatalogSelectors(
          entryPoints: optimisticSelectors.entryPoints,
          facetGroups: existing.selectors.facetGroups
        )
      )
      state = .loaded(updated)
      loadedFeeds[href] = updated
      activeEntryPointURL = href
      lastLoadedURL = href
      scrollGeneration &+= 1
      Log.warn(#file, "[PERF] applyEntryPoint '\(facet.title)': view cache HIT \(Int((CFAbsoluteTimeGetCurrent()-t0)*1000))ms")
      return
    }

    // Try repository cache — feed data exists but views need creation
    if let cachedFeed = repository.cachedFeed(for: href) {
      let base = withSideloadedLane(Self.mapFeed(cachedFeed, bookRegistry: bookRegistry))
      let newContent = CatalogContent(
        title: base.title, feed: base.feed,
        selectors: CatalogSelectors(entryPoints: optimisticSelectors.entryPoints, facetGroups: base.selectors.facetGroups)
      )
      state = .loaded(newContent)
      loadedFeeds[href] = newContent
      activeEntryPointURL = href
      lastLoadedURL = href
      scrollGeneration &+= 1
      Log.warn(#file, "[PERF] applyEntryPoint '\(facet.title)': repo cache HIT \(Int((CFAbsoluteTimeGetCurrent()-t0)*1000))ms")
      return
    }

    // Cache miss — show skeleton with tabs visible
    state = .switchingEntryPoint(optimisticSelectors)

    do {
      if let feed = try await repository.loadTopLevelCatalog(at: href) {
        let base = withSideloadedLane(Self.mapFeed(feed, bookRegistry: bookRegistry))
        let newContent = CatalogContent(
          title: base.title, feed: base.feed,
          selectors: CatalogSelectors(entryPoints: optimisticSelectors.entryPoints, facetGroups: base.selectors.facetGroups)
        )
        state = .loaded(newContent)
        loadedFeeds[href] = newContent
        activeEntryPointURL = href
        lastLoadedURL = href
        scrollGeneration &+= 1
        Log.warn(#file, "[PERF] applyEntryPoint '\(facet.title)': network fetch \(Int((CFAbsoluteTimeGetCurrent()-t0)*1000))ms")
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
      // Serve the new library's account-scoped cache instantly (SWR); do NOT
      // invalidate. `reload` handles the load-task cancel + `.loading`
      // transition.
      await reload(invalidatingCache: false)
    }
  }
}

// MARK: - Models

struct CatalogLaneModel: Identifiable {
  /// Content-derived identity: a lane IS its title + group href within a feed.
  ///
  /// Previously a fresh `UUID()` per instance, so every re-map (facet apply,
  /// registry update, entry-point switch) minted brand-new identities and
  /// `ForEach` tore down + rebuilt every lane — each horizontal ScrollView and
  /// all its covers — instead of diffing in place, flashing the whole feed. The
  /// codebase already treats `title` + `moreURL` as a lane's identity (the
  /// `catalogLaneMore(title:url:)` route), so deriving `id` from them is stable
  /// across re-maps and consistent with existing assumptions.
  var id: String { "\(title)|\(moreURL?.absoluteString ?? "")" }
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
  struct MappedCatalog: Sendable {
    let title: String
    let entries: [CatalogEntry]
    let lanes: [CatalogLaneModel]
    let ungroupedBooks: [TPPBook]
    let facetGroups: [CatalogFilterGroup]
    let entryPoints: [CatalogFilter]
  }

  static func mapFeed(_ feed: CatalogFeed, currentURL: URL? = nil, bookRegistry: TPPBookRegistryProvider) -> MappedCatalog {
    if let opds2 = feed.opds2Feed {
      return mapOPDS2Feed(opds2, title: feed.title, entries: feed.entries, currentURL: currentURL)
    }

    let title = feed.title
    let entries = feed.entries
    let feedObjc = feed.opdsFeed

    switch feedObjc.type {
    case .acquisitionGrouped:
      let (facetGroups, entryPoints) = extractFacets(from: feedObjc)
      let (lanes, _) = buildGroupedContent(from: feedObjc, bookRegistry: bookRegistry)
      return MappedCatalog(
        title: title, entries: entries, lanes: lanes, ungroupedBooks: [],
        facetGroups: facetGroups.isEmpty ? [] : facetGroups, entryPoints: entryPoints
      )
    case .acquisitionUngrouped:
      let ungroupedBooks = (feedObjc.entries as? [TPPOPDSEntry])?.compactMap { makeBook(from: $0, bookRegistry: bookRegistry) } ?? []
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

  private static func mapOPDS2Feed(_ feed: OPDS2Feed, title: String, entries: [CatalogEntry], currentURL: URL? = nil) -> MappedCatalog {
    Log.info(#file, "[OPDS2-DIAG] Mapping OPDS2 feed: \"\(feed.title)\", grouped=\(feed.isGroupedFeed), publications=\(feed.isPublicationFeed), navigation=\(feed.isNavigationFeed)")

    if feed.isGroupedFeed {
      let lanes = buildOPDS2GroupedContent(from: feed)
      let (facetGroups, entryPoints) = extractOPDS2Facets(from: feed, currentURL: currentURL)
      return MappedCatalog(title: title, entries: entries, lanes: lanes, ungroupedBooks: [], facetGroups: facetGroups, entryPoints: entryPoints)
    } else if feed.isPublicationFeed {
      let books = feed.publications?.compactMap { $0.toBook() } ?? []
      Log.info(#file, "[OPDS2-DIAG] Mapped \(books.count) books from publication feed")
      let (facetGroups, entryPoints) = extractOPDS2Facets(from: feed, currentURL: currentURL)
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
      lanes.append(CatalogLaneModel(title: group.title, books: books, moreURL: group.moreURL))
    }
    Log.info(#file, "[OPDS2-DIAG] Built \(lanes.count) lanes from OPDS2 groups, total books=\(lanes.reduce(0) { $0 + $1.books.count })")
    return lanes
  }

  static func extractOPDS2Facets(
    from feed: OPDS2Feed,
    currentURL: URL? = nil
  ) -> ([CatalogFilterGroup], [CatalogFilter]) {
    var entryPoints: [CatalogFilter] = []
    if let links = feed.links {
      for link in links {
        if let href = link.hrefURL,
           (link.href.contains("entrypoint=") || link.rel == "http://opds-spec.org/facet"),
           let title = link.title, !title.isEmpty {
          let urlMatch = currentURL.map { urlsMatchForFacet(href, $0) } ?? false
          let isActive = urlMatch || link.properties?.numberOfItems != nil
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
        let isActive = isFacetActive(href: url, link: link, currentURL: currentURL)
        return CatalogFilter(id: link.href, title: link.title, href: url, active: isActive)
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

  /// OPDS 2 has no standard "active facet" flag. The CM reloads the feed at
  /// the chosen facet's href, so a URL match is the authoritative signal.
  /// When no facet href matches the current URL, we fall back to the
  /// weaker `numberOfItems` hint so feeds that still rely on it continue
  /// to highlight something.
  private static func isFacetActive(href: URL, link: OPDS2FacetLink, currentURL: URL?) -> Bool {
    if let currentURL, urlsMatchForFacet(href, currentURL) {
      return true
    }
    return link.isActive
  }

  private static func urlsMatchForFacet(_ a: URL, _ b: URL) -> Bool {
    guard let aComps = URLComponents(url: a, resolvingAgainstBaseURL: false),
          let bComps = URLComponents(url: b, resolvingAgainstBaseURL: false) else {
      return a == b
    }
    if aComps.host != bComps.host { return false }
    if aComps.path != bComps.path { return false }
    let aItems = Set(aComps.queryItems ?? [])
    let bItems = Set(bComps.queryItems ?? [])
    return aItems == bItems
  }

  private static func buildGroupedContent(from feed: TPPOPDSFeed, bookRegistry: TPPBookRegistryProvider) -> ([CatalogLaneModel], [TPPBook]) {
    var titleToBooks: [String: [TPPBook]] = [:]
    var titleToMoreURL: [String: URL?] = [:]
    var orderedTitles: [String] = []
    if let entries = feed.entries as? [TPPOPDSEntry] {
      for entry in entries {
        if let group = entry.groupAttributes, let book = makeBook(from: entry, bookRegistry: bookRegistry) {
          let title = group.title ?? ""
          if titleToBooks[title] == nil { orderedTitles.append(title) }
          titleToBooks[title, default: []].append(book)
          if titleToMoreURL[title] == nil { titleToMoreURL[title] = group.href }
        }
      }
    }
    return (orderedTitles.map { title in
      CatalogLaneModel(title: title, books: titleToBooks[title] ?? [], moreURL: titleToMoreURL[title] ?? nil)
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

  static func makeBook(from entry: TPPOPDSEntry, bookRegistry: TPPBookRegistryProvider) -> TPPBook? {
    guard var book = TPPBook(entry: entry) else { return nil }
    if let updated = bookRegistry.updatedBookMetadata(book) { book = updated }
    if book.defaultBookContentType == .unsupported { return nil }
    if book.defaultAcquisition == nil { return nil }
    return book
  }
}
