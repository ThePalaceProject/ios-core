import SwiftUI

struct CatalogLaneMoreView: View {
  let title: String
  let url: URL
  @State private var books: [TPPBook] = []
  @State private var isLoading = true
  @State private var error: String?

  var body: some View {
    VStack(spacing: 0) {
      // Facet bar / entry points placeholder: future SwiftUI port of TPPFacetBarView
      if !facetGroups.isEmpty {
        FacetsSelectorView(facetGroups: facetGroups) { facet in
          Task { await applyFacet(facet) }
        }
      }
      if isLoading {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let error {
        Text(error).padding()
      } else {
        BookListView(books: books, isLoading: $isLoading) { book in
          presentBookDetail(book)
        }
      }
    }
    .navigationTitle(title)
    .task { await load() }
  }

  @State private var facetGroups: [TPPCatalogFacetGroup] = []

  private func load() async {
    defer { isLoading = false }
    do {
      let client = URLSessionNetworkClient()
      let parser = OPDSParser()
      let api = DefaultCatalogAPI(client: client, parser: parser)
      if let feed = try await api.fetchFeed(at: url) {
        if let entries = feed.opdsFeed.entries as? [TPPOPDSEntry] {
          books = entries.compactMap { CatalogViewModel.makeBook(from: $0) }
        }
        // Build facet groups from the ObjC helper, like legacy code
        if let objcFeed = feed.opdsFeed as TPPOPDSFeed? {
          if objcFeed.type == .acquisitionUngrouped {
            let ungrouped = TPPCatalogUngroupedFeed(opdsFeed: objcFeed)
            facetGroups = (ungrouped?.facetGroups as? [TPPCatalogFacetGroup]) ?? []
          }
        }
      }
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func presentBookDetail(_ book: TPPBook) {
    let detailVC = BookDetailHostingController(book: book)
    TPPRootTabBarController.shared().pushViewController(detailVC, animated: true)
  }

  @MainActor
  private func applyFacet(_ facet: TPPCatalogFacet) async {
    guard let href = facet.href else { return }
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
      let client = URLSessionNetworkClient()
      let parser = OPDSParser()
      let api = DefaultCatalogAPI(client: client, parser: parser)
      if let feed = try await api.fetchFeed(at: href) {
        if let entries = feed.opdsFeed.entries as? [TPPOPDSEntry] {
          books = entries.compactMap { CatalogViewModel.makeBook(from: $0) }
        }
        if feed.opdsFeed.type == .acquisitionUngrouped {
          let ungrouped = TPPCatalogUngroupedFeed(opdsFeed: feed.opdsFeed)
          facetGroups = ungrouped?.facetGroups as? [TPPCatalogFacetGroup] ?? []
        }
      }
    } catch {
      self.error = error.localizedDescription
    }
  }
}


