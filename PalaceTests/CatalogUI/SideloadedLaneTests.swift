//
//  SideloadedLaneTests.swift
//  PalaceTests
//
//  Module D (swarm_495a88d9 / PP-2679): the "Side Loaded" catalog lane.
//
//  Covers two layers:
//   1. The pure `MappedCatalog.toCatalogContent(prepending:)` bridge — proves the
//      injected lanes force `.grouped` for every base-feed shape (grouped /
//      ungrouped / empty) and that an empty prepend list is identical to the
//      un-injected baseline (lane ABSENT).
//   2. The `CatalogViewModel` wiring — proves the single choke-point helper
//      `withSideloadedLane(_:)` runs on the load path AND, critically, on the
//      `applyFacet` cache-HIT synchronous fast path (:283) that a per-site patch
//      would silently miss.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace
@testable import PalaceCatalog

// MARK: - Pure bridge: toCatalogContent(prepending:)

final class SideloadedLaneBridgeTests: XCTestCase {

  private func mapped(
    lanes: [CatalogLaneModel] = [],
    ungrouped: [TPPBook] = [],
    title: String = "Base"
  ) -> CatalogViewModel.MappedCatalog {
    CatalogViewModel.MappedCatalog(
      title: title, entries: [], lanes: lanes, ungroupedBooks: ungrouped,
      facetGroups: [], entryPoints: []
    )
  }

  private func sideloadedLane(_ books: [TPPBook]) -> [CatalogLaneModel] {
    [CatalogLaneModel(title: "Side Loaded", books: books, moreURL: nil)]
  }

  private func lanes(from content: CatalogContent) -> [CatalogLaneModel]? {
    if case .grouped(let l) = content.feed { return l }
    return nil
  }

  // MARK: present (provider non-empty)

  func testPrepending_groupedBase_sideloadedLaneIsFirst_baseLanesRetained() {
    let sideBook = TPPBookMocker.snapshotEPUB()
    let baseBook = TPPBookMocker.snapshotAudiobook()
    let base = mapped(lanes: [CatalogLaneModel(title: "Popular", books: [baseBook], moreURL: nil)])

    let content = base.toCatalogContent(prepending: sideloadedLane([sideBook]))

    guard let lanes = lanes(from: content) else { return XCTFail("Expected .grouped") }
    XCTAssertEqual(lanes.count, 2, "Side Loaded lane + base lane")
    XCTAssertEqual(lanes.first?.title, "Side Loaded")
    XCTAssertEqual(lanes.first?.books.map(\.identifier), [sideBook.identifier])
    XCTAssertEqual(lanes.last?.title, "Popular", "Base lane must be preserved after the injected lane")
    XCTAssertEqual(lanes.last?.books.map(\.identifier), [baseBook.identifier])
  }

  func testPrepending_ungroupedBase_forcesGrouped_keepsOriginalBooks() {
    let sideBook = TPPBookMocker.snapshotEPUB()
    let baseBook = TPPBookMocker.snapshotAudiobook()
    let base = mapped(ungrouped: [baseBook])

    let content = base.toCatalogContent(prepending: sideloadedLane([sideBook]))

    guard let lanes = lanes(from: content) else {
      return XCTFail("Ungrouped base + injected lane must force .grouped")
    }
    XCTAssertEqual(lanes.first?.title, "Side Loaded")
    XCTAssertEqual(lanes.first?.books.map(\.identifier), [sideBook.identifier])
    // The ungrouped books must NOT be dropped — they are wrapped into a lane.
    let allBooks = lanes.flatMap { $0.books.map(\.identifier) }
    XCTAssertTrue(allBooks.contains(baseBook.identifier),
                  "Original ungrouped books must survive the force-to-grouped conversion")
  }

  func testPrepending_emptyBase_groupedWithOnlySideloadedLane() {
    let sideBook = TPPBookMocker.snapshotEPUB()
    let base = mapped() // empty base feed — the DRM side-loading use-case

    let content = base.toCatalogContent(prepending: sideloadedLane([sideBook]))

    guard let lanes = lanes(from: content) else {
      return XCTFail("Empty base + injected lane must force .grouped")
    }
    XCTAssertEqual(lanes.count, 1)
    XCTAssertEqual(lanes.first?.title, "Side Loaded")
    XCTAssertEqual(lanes.first?.books.map(\.identifier), [sideBook.identifier])
  }

  // MARK: absent (provider empty → baseline shape unchanged)

  func testPrependingEmpty_groupedBase_shapeUnchanged() {
    let base = mapped(lanes: [CatalogLaneModel(title: "Popular", books: [], moreURL: nil)])
    let content = base.toCatalogContent(prepending: [])
    guard case .grouped(let l) = content.feed else { return XCTFail("Expected .grouped") }
    XCTAssertEqual(l.count, 1)
    XCTAssertEqual(l.first?.title, "Popular", "No injected lane when the prepend list is empty")
  }

  func testPrependingEmpty_ungroupedBase_shapeUnchanged() {
    let base = mapped(ungrouped: [TPPBookMocker.snapshotEPUB()])
    let content = base.toCatalogContent(prepending: [])
    guard case .ungrouped(let books) = content.feed else {
      return XCTFail("Empty prepend must leave an ungrouped feed ungrouped")
    }
    XCTAssertEqual(books.count, 1)
  }

  func testPrependingEmpty_emptyBase_shapeUnchanged() {
    let base = mapped()
    let content = base.toCatalogContent(prepending: [])
    guard case .empty = content.feed else {
      return XCTFail("Empty prepend must leave an empty feed empty (lane ABSENT)")
    }
  }
}

// MARK: - VM wiring: withSideloadedLane choke point

@MainActor
final class SideloadedLaneViewModelTests: XCTestCase {

  private var repository: CatalogRepositoryTestMock!
  private var cancellables: Set<AnyCancellable>!
  private let feedURL = URL(string: "https://example.com/catalog")!
  private let facetURL = URL(string: "https://example.com/facet")!

  override func setUp() {
    super.setUp()
    repository = CatalogRepositoryTestMock()
    cancellables = []
  }

  override func tearDown() {
    repository = nil
    cancellables = nil
    super.tearDown()
  }

  // MARK: OPDS2 stub-feed helpers

  private func makePublication(id: String) -> OPDS2Publication {
    OPDS2Publication(
      links: [
        OPDS2Link(
          href: "https://example.com/borrow/\(id)",
          type: "application/epub+zip",
          rel: "http://opds-spec.org/acquisition/borrow"
        )
      ],
      metadata: OPDS2Publication.Metadata(id: id, title: "Title \(id)"),
      images: nil
    )
  }

  private func groupedFeed(laneTitle: String, pubID: String) -> CatalogFeed {
    let feed = OPDS2Feed(
      metadata: OPDS2FeedMetadata(title: "Feed"),
      groups: [
        OPDS2Group(
          metadata: OPDS2GroupMetadata(title: laneTitle),
          links: nil,
          publications: [makePublication(id: pubID)],
          navigation: nil
        )
      ]
    )
    return CatalogFeed(opds2Feed: feed)
  }

  private func makeViewModel(provider: @escaping () -> [TPPBook]) -> CatalogViewModel {
    CatalogViewModel(
      repository: repository,
      topLevelURLProvider: { [feedURL] in feedURL },
      bookRegistry: TPPBookRegistryMock(),
      imageCache: ImageCache.shared,
      sideloadedLaneBooksProvider: provider,
      reachability: MockReachability(initiallyConnected: true)
    )
  }

  private func awaitLoaded(_ vm: CatalogViewModel) async {
    let exp = XCTestExpectation(description: "loaded")
    vm.$state.sink { if case .loaded = $0 { exp.fulfill() } }.store(in: &cancellables)
    await vm.load()
    await fulfillment(of: [exp], timeout: 5.0)
  }

  private func groupedLanes(_ vm: CatalogViewModel) -> [CatalogLaneModel]? {
    guard case .grouped(let lanes) = vm.state.content?.feed else { return nil }
    return lanes
  }

  // MARK: - load path (flag ON analog: provider non-empty)

  func testLoad_providerNonEmpty_prependsSideloadedLaneAtTop() async {
    let sideBook = TPPBookMocker.snapshotEPUB()
    repository.loadTopLevelCatalogResult = groupedFeed(laneTitle: "Popular", pubID: "base-1")
    let vm = makeViewModel(provider: { [sideBook] })

    await awaitLoaded(vm)

    guard let lanes = groupedLanes(vm) else {
      return XCTFail("Expected grouped content with the injected lane, got \(vm.state)")
    }
    XCTAssertEqual(lanes.first?.title, "Side Loaded")
    XCTAssertEqual(lanes.first?.books.map(\.identifier), [sideBook.identifier])
  }

  func testLoad_providerEmpty_noSideloadedLane() async {
    repository.loadTopLevelCatalogResult = groupedFeed(laneTitle: "Popular", pubID: "base-1")
    let vm = makeViewModel(provider: { [] })

    await awaitLoaded(vm)

    let titles: [String] = {
      switch vm.state.content?.feed {
      case .grouped(let lanes): return lanes.map(\.title)
      default: return []
      }
    }()
    XCTAssertFalse(titles.contains("Side Loaded"),
                   "Empty provider (flag off / empty registry) must not inject a lane")
  }

  // MARK: - applyFacet cache-HIT path (:283) — the finding-1 landmine

  /// Drives the synchronous cache-HIT branch of `applyFacet` (repository has a
  /// cached feed) with a non-empty provider and asserts the Side Loaded lane
  /// still appears. A per-site patch that only touched the cache-MISS path would
  /// fail here. Proven-cache-hit via: repository load count unchanged (no
  /// network) AND scrollGeneration incremented by the cache-hit branch.
  func testApplyFacet_cacheHit_stillShowsSideloadedLane() async {
    let sideBook = TPPBookMocker.snapshotPDF()
    repository.loadTopLevelCatalogResult = groupedFeed(laneTitle: "Popular", pubID: "base-1")
    let vm = makeViewModel(provider: { [sideBook] })

    // Establish a .loaded state so applyFacet has current content to work from.
    await awaitLoaded(vm)
    let loadCallsBeforeFacet = repository.loadTopLevelCatalogCallCount
    let scrollBeforeFacet = vm.scrollGeneration

    // Arm the synchronous cache-HIT fast path (:283).
    repository.cachedFeedResult = groupedFeed(laneTitle: "Filtered", pubID: "facet-1")
    await vm.applyFacet(CatalogFilter(id: "f1", title: "Fiction", href: facetURL, active: false))

    XCTAssertEqual(repository.loadTopLevelCatalogCallCount, loadCallsBeforeFacet,
                   "Cache HIT must not hit the network")
    XCTAssertGreaterThan(vm.scrollGeneration, scrollBeforeFacet,
                         "The synchronous cache-HIT branch must have run")

    guard let lanes = groupedLanes(vm) else {
      return XCTFail("Cache-HIT applyFacet must still produce a grouped feed with the lane, got \(vm.state)")
    }
    XCTAssertEqual(lanes.first?.title, "Side Loaded",
                   "Side Loaded lane must survive the applyFacet cache-HIT fast path")
    XCTAssertEqual(lanes.first?.books.map(\.identifier), [sideBook.identifier])
  }
}
