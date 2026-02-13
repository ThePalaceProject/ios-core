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
                Button(action: { onSelect(book) }, label: {
                    // Use cached model instead of creating new one each render
                    BookCell(model: modelCache.model(for: book), previewEnabled: previewEnabled)
                })
                .buttonStyle(.plain)
                .applyBorderStyle()
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

    /// Prefetches images for cells that are about to become visible
    private func prefetchUpcomingImages(currentBook: TPPBook) {
        guard let currentIndex = books.firstIndex(where: { $0.identifier == currentBook.identifier }) else {
            return
        }

        // Prefetch next N items
        let startIndex = currentIndex + 1
        let endIndex = min(startIndex + prefetchBuffer, books.count)

        guard startIndex < endIndex else { return }

        let upcomingBooks = Array(books[startIndex..<endIndex])

        // Prefetch in background
        Task.detached(priority: .utility) {
            for book in upcomingBooks {
                // Prefetch thumbnail images
                await TPPBookCoverRegistry.shared.thumbnailImage(for: book)
            }
        }

        // Also preload models for upcoming books
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
