import SwiftUI

struct BookListView: View {
    let books: [TPPBook]
    @Binding var isLoading: Bool
    let onSelect: (TPPBook) -> Void
    var onLoadMore: (() async -> Void)?
    var isLoadingMore: Bool = false
    var previewEnabled: Bool = true
    @State private var containerWidth: CGFloat = UIScreen.main.bounds.width
    @State private var screenSize: CGSize = UIScreen.main.bounds.size

    /// Shared model cache for performance - reuses BookCellModel instances
    private let modelCache = BookCellModelCache.shared

    /// Number of items to prefetch beyond visible range.
    /// Kept low to avoid memory pressure from concurrent image decodes
    /// when browsing catalogs with many entries (e.g., Stanislaus County PP-3682).
    private let prefetchBuffer = 4

    var body: some View {
        LazyVGrid(columns: gridLayout, spacing: 0) {
            ForEach(books, id: \.identifier) { book in
                // PP-4326: keep the visual tree exactly as on 3.0.1 — wrap
                // the cell in a Button so taps anywhere on the row open
                // detail — and replace the row's ACCESSIBILITY tree with
                // a custom one via .accessibilityRepresentation. The
                // representation is a VStack of real SwiftUI Buttons —
                // one for the row-info "Open book details" action, then
                // one per available BookButtonType (Borrow/Read/Listen/
                // Return). Each Button is a structural accessibility
                // element so VoiceOver linear-swipe reaches each in turn
                // and double-tap activates them. The visible BookCell
                // tree is untouched; only VoiceOver sees the
                // representation.
                let cellModel = modelCache.model(for: book)
                Button(action: { onSelect(book) }, label: {
                    BookCell(model: cellModel, previewEnabled: previewEnabled)
                })
                .buttonStyle(.plain)
                .applyBorderStyle()
                .accessibilityRepresentation {
                    bookRowAccessibilityRepresentation(book: book, model: cellModel)
                }
                .onAppear {
                    handleCellAppear(book: book)
                }
            }

            if isLoadingMore {
                paginationLoadingIndicator
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        containerWidth = geometry.size.width
                        screenSize = UIScreen.main.bounds.size
                    }
                    .onChange(of: geometry.size.width) { newWidth in
                        containerWidth = newWidth
                    }
            }
        )
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            screenSize = UIScreen.main.bounds.size
        }
    }

    // MARK: - Cell Appearance Handler

    private func handleCellAppear(book: TPPBook) {
        // Trigger load more if at end
        if let onLoadMore = onLoadMore, book.identifier == books.last?.identifier {
            Task { await onLoadMore() }
        }

        // Prefetch images for upcoming cells
        prefetchUpcomingImages(currentBook: book)
    }

    // MARK: - Image Prefetching

    /// Prefetches images for cells that are about to become visible.
    /// Snapshots the books array to avoid index-out-of-bounds if the array
    /// changes between finding the current index and slicing.
    private func prefetchUpcomingImages(currentBook: TPPBook) {
        let snapshot = books
        guard let currentIndex = snapshot.firstIndex(where: { $0.identifier == currentBook.identifier }) else {
            return
        }

        let startIndex = currentIndex + 1
        guard startIndex < snapshot.count else { return }
        let endIndex = min(startIndex + prefetchBuffer, snapshot.count)

        let upcomingBooks = Array(snapshot[startIndex..<endIndex])

        Task.detached(priority: .utility) {
            for book in upcomingBooks {
                await TPPBookCoverRegistry.shared.thumbnailImage(for: book)
            }
        }

        Task { @MainActor in
            modelCache.preload(books: upcomingBooks)
        }
    }

    private var paginationLoadingIndicator: some View {
        PulsatingDotsLoader()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .gridCellColumns(gridLayout.count)
    }

    // MARK: - PP-4326 Accessibility Representation

    /// Custom accessibility tree for a single book row. Returned by
    /// `.accessibilityRepresentation { ... }` on the row Button — the
    /// visible BookCell tree is left untouched and VoiceOver sees only
    /// the elements built here. Each element is a real SwiftUI Button,
    /// so each is naturally a focusable VoiceOver element with double-tap
    /// activation; the structural sibling layout means linear-swipe
    /// navigates from row-info → Borrow → Read → Listen → Return one
    /// element at a time.
    @ViewBuilder
    private func bookRowAccessibilityRepresentation(
        book: TPPBook,
        model: BookCellModel
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Row-info Button — "Title, by Author. Button. Opens book
            // details." Double-tap opens the detail screen.
            Button(action: { onSelect(book) }) {
                Text(book.voiceOverLabel)
            }
            .accessibilityHint(Strings.Accessibility.opensBookDetails)

            // One Button per available BookButtonType, mirroring what
            // BookButtonsView renders visually for this cell. Each is
            // its own focusable VoiceOver element.
            ForEach(availableButtonTypes(for: model), id: \.self) { type in
                Button(type.title(for: book)) {
                    model.callDelegate(for: type)
                }
            }
        }
    }

    /// Mirrors BookButtonsView's filter — when previewEnabled is false,
    /// sample/audiobookSample buttons are not surfaced visually, so they
    /// shouldn't appear in the accessibility tree either.
    private func availableButtonTypes(for model: BookCellModel) -> [BookButtonType] {
        guard !previewEnabled else { return model.buttonTypes }
        return model.buttonTypes.filter { $0 != .sample && $0 != .audiobookSample }
    }

    private var gridLayout: [GridItem] {
        let isLandscape = screenSize.width > screenSize.height
        let isIPad = UIDevice.current.userInterfaceIdiom == .pad

        if isIPad {
            let columnCount = isLandscape ? 3 : 2
            return Array(repeating: GridItem(.flexible(), spacing: 0), count: columnCount)
        } else {
            return [GridItem(.flexible(), spacing: 0)]
        }
    }
}

extension View {
    func applyBorderStyle() -> some View {
        modifier(BorderStyleModifier())
    }
}

// MARK: - Pulsating Dots Loader
struct PulsatingDotsLoader: View {
    @State private var pulse1: Bool = false
    @State private var pulse2: Bool = false
    @State private var pulse3: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.gray.opacity(0.25))
                .frame(width: 12, height: 12)
                .opacity(pulse1 ? 0.6 : 1.0)

            Circle()
                .fill(Color.gray.opacity(0.25))
                .frame(width: 12, height: 12)
                .opacity(pulse2 ? 0.6 : 1.0)

            Circle()
                .fill(Color.gray.opacity(0.25))
                .frame(width: 12, height: 12)
                .opacity(pulse3 ? 0.6 : 1.0)
        }
        .onAppear {
            accessibleWithAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse1 = true
            }
            accessibleWithAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true).delay(0.3)) {
                pulse2 = true
            }
            accessibleWithAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true).delay(0.6)) {
                pulse3 = true
            }
        }
    }
}
