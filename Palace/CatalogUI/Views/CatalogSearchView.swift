import SwiftUI
import Combine
import UIKit
import PalaceNetwork
import PalaceCatalog
import PalaceBookModel

// MARK: - Accessibility focus target
// PP-4641: after a search completes, VoiceOver focus must remain on the search
// field (WCAG 3.2.2 On Input) rather than drift into the results list. (This
// reverses PP-3834, which had deliberately moved focus into the results.)
private enum SearchAccessibilityFocus: Hashable {
    case searchField
}

// MARK: - Post-search accessibility gate (PP-4641)
/// Pure decision for whether, when a search finishes, we should perform the
/// post-search VoiceOver work: re-assert focus on the search field and announce
/// the result count. Extracted so the gating logic is unit-testable without a
/// live VoiceOver session. The view owns the actual focus/announcement effects.
enum SearchAccessibilityFocusPolicy {
    static func shouldHandlePostSearchAccessibility(
        isLoading: Bool,
        query: String,
        isVoiceOverRunning: Bool
    ) -> Bool {
        !isLoading
            && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && isVoiceOverRunning
    }
}

// MARK: - SearchView
struct CatalogSearchView: View {
    @StateObject private var viewModel: CatalogSearchViewModel
    @FocusState private var isSearchFieldFocused: Bool
    @AccessibilityFocusState private var accessibilityFocus: SearchAccessibilityFocus?
    let books: [TPPBook]
    let onBookSelected: (TPPBook) -> Void
    let downloadCenter: MyBooksDownloadCenter

    init(
        repository: CatalogRepositoryProtocol,
        baseURL: @escaping () -> URL?,
        books: [TPPBook],
        onBookSelected: @escaping (TPPBook) -> Void,
        downloadCenter: MyBooksDownloadCenter = AppContainer.production().downloadCenter
    ) {
        self._viewModel = StateObject(wrappedValue: CatalogSearchViewModel(
            repository: repository,
            baseURL: baseURL,
            bookCellModelCache: AppContainer.production().bookCellModelCache
        ))
        self.books = books
        self.onBookSelected = onBookSelected
        self.downloadCenter = downloadCenter
    }

    init(
        books: [TPPBook],
        onBookSelected: @escaping (TPPBook) -> Void
    ) {

        // Use AppContainer's shared, cached CatalogRepository rather than a
        // throwaway per-init instance (swarm_27c181b5 A5).
        self._viewModel = StateObject(wrappedValue: CatalogSearchViewModel(
            repository: AppContainer.production().catalogRepository,
            baseURL: { nil },
            bookCellModelCache: AppContainer.production().bookCellModelCache
        ))
        self.books = books
        self.onBookSelected = onBookSelected
        self.downloadCenter = AppContainer.production().downloadCenter
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar

            if viewModel.formatEntries.count > 1 {
                formatFilterRow
            }

            resultsScrollView
        }
        .onAppear {
            viewModel.updateBooks(books)
            viewModel.loadFormatEntryPoints()
            // when returning from book detail, registry state may have
            // changed (cancel hold, return, etc.) while a throttled notification
            // was in flight or the view was off-screen. Force a full reconcile.
            viewModel.applyRegistryUpdates(changedIdentifier: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isSearchFieldFocused = true
            }
        }
        .onChange(of: books) { _, newBooks in
            viewModel.updateBooks(newBooks)
        }
        .onReceive(registryChangePublisher) { changedId in
            viewModel.applyRegistryUpdates(changedIdentifier: changedId)
        }
        .onReceive(downloadProgressPublisher) { changedId in
            viewModel.applyRegistryUpdates(changedIdentifier: changedId)
        }
    }

    // MARK: - Publishers

    private var registryChangePublisher: AnyPublisher<String, Never> {
        // Migrated off `.TPPBookRegistryStateDidChange` to the registry's per-book
        // `bookStatePublisher` (swarm_8ce6f5ae WS3); emit the changed identifier so
        // just the affected result row refreshes. Resolved from the shared graph to
        // match this view's existing `AppContainer.production()` defaults.
        AppContainer.production().bookRegistry.bookStatePublisher
            .map { $0.0 }
            .throttle(for: .milliseconds(350), scheduler: DispatchQueue.main, latest: true)
            .eraseToAnyPublisher()
    }

    private var downloadProgressPublisher: AnyPublisher<String, Never> {
        downloadCenter.downloadProgressPublisher
            .throttle(for: .milliseconds(350), scheduler: DispatchQueue.main, latest: true)
            .map { $0.0 }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}

// MARK: - Private Views
private extension CatalogSearchView {
    var resultsScrollView: some View {
        ScrollViewReader { proxy in
            resultsContent
                .scrollDismissesKeyboard(.immediately)
                .simultaneousGesture(
                    TapGesture().onEnded { isSearchFieldFocused = false }
                )
                .onChange(of: viewModel.searchId) { _, _ in
                    proxy.scrollTo("search-results-top", anchor: .top)
                }
                .onChange(of: viewModel.isLoading) { _, isLoading in
                    handlePostSearchAccessibility(isLoading: isLoading)
                }
        }
    }

    var resultsContent: some View {
        ScrollView {
            if viewModel.isLoading && viewModel.filteredBooks.isEmpty {
                // Initial search load: show a content-shaped skeleton list
                // (mirrors the result rows) instead of a blank screen + a lone
                // field spinner. Built on the unified Skeleton primitives.
                VStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { _ in
                        BookRowSkeletonView()
                    }
                }
                // Match `BookListView`'s insets (the loaded results container)
                // so rows don't shift horizontally when the search completes.
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .id("search-results-top")
            } else if viewModel.shouldShowNoResultsState {
                // BUG-003: When a completed search returns zero results, render
                // a visible empty state rather than a blank screen so the user
                // can distinguish "no matches" from a hung request.
                noResultsEmptyState
                    .id("search-results-top")
            } else {
                BookListView(
                    books: viewModel.filteredBooks,
                    isLoading: $viewModel.isLoading,
                    onSelect: onBookSelected,
                    onLoadMore: { @MainActor in await viewModel.loadNextPage() },
                    isLoadingMore: viewModel.isLoadingMore,
                    previewEnabled: false
                )
                .id("search-results-top")
            }
        }
        .accessibilityIdentifier(AccessibilityID.Search.resultsScrollView)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("Search results list", comment: "VoiceOver label for search results area"))
        .accessibilityValue(Strings.SearchAnnouncements.searchResultsListValue(bookCount: viewModel.filteredBooks.count))
        .accessibilityHint(Strings.SearchAnnouncements.searchResultsListHint)
    }

    /// "No results" empty state shown when a completed search returns zero books.
    /// Visibility is governed by `viewModel.shouldShowNoResultsState`, which guards
    /// against the loading and "no query yet" cases — see BUG-003.
    var noResultsEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(Strings.SearchAnnouncements.noResultsTitle)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(Strings.SearchAnnouncements.noResultsBody)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 48)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.Search.noResultsView)
    }

    /// PP-4641: when a search finishes under VoiceOver, keep focus on the search
    /// field (so activating Search isn't an unexpected change of context) and
    /// announce the result count. The short delay lets the results list render
    /// first, so our focus assertion wins the race against SwiftUI's automatic
    /// relocation into the freshly-changed list.
    func handlePostSearchAccessibility(isLoading: Bool) {
        guard SearchAccessibilityFocusPolicy.shouldHandlePostSearchAccessibility(
            isLoading: isLoading,
            query: viewModel.searchQuery,
            isVoiceOverRunning: UIAccessibility.isVoiceOverRunning
        ) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            // Re-assert focus on the search field. In the common case focus never
            // left the field, so this is a no-op (no redundant re-announcement);
            // if SwiftUI drifted focus into the results, this brings it back.
            accessibilityFocus = .searchField
            // Preserve the result-count announcement (no regression vs. prior behavior).
            let value = Strings.SearchAnnouncements.searchResultsListValue(bookCount: viewModel.filteredBooks.count)
            let listLabel = NSLocalizedString("Search results list", comment: "VoiceOver label for search results area")
            UIAccessibility.post(notification: .announcement, argument: "\(listLabel), \(value)")
        }
    }

    var formatFilterRow: some View {
        HStack {
            Picker(
                NSLocalizedString("Format", comment: "Format filter picker label"),
                selection: Binding(
                    get: { viewModel.selectedFormatIndex },
                    set: { viewModel.selectFormat(at: $0) }
                )
            ) {
                ForEach(viewModel.formatEntries.indices, id: \.self) { idx in
                    Text(viewModel.formatEntries[idx].title).tag(idx)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .accessibilityIdentifier(AccessibilityID.Search.formatFilterRow)
        }
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 12)
    }

    var searchBar: some View {
        ZStack {
            TextField(
                NSLocalizedString("Search Catalog", comment: ""),
                text: Binding(
                    get: { viewModel.searchQuery },
                    set: { viewModel.updateSearchQuery($0) }
                )
            )
            .accessibilityIdentifier(AccessibilityID.Search.searchField)
            .focused($isSearchFieldFocused)
            .accessibilityFocused($accessibilityFocus, equals: .searchField)
            .submitLabel(.search)
            .padding(8)
            .padding(.trailing, 40)
            .background(Color.gray.opacity(0.2))
            .cornerRadius(10)
            .padding(.horizontal)

            HStack {
                Spacer()

                if viewModel.isLoading {
                    ProgressView()
                        .padding(.trailing, 8)
                } else if !viewModel.searchQuery.isEmpty {
                    Button(action: { viewModel.clearSearch() }, label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.gray)
                    })
                    .accessibilityLabel(Strings.Generic.clearSearch)
                    .padding(.trailing, 8)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }
}
