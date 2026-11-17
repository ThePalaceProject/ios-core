import SwiftUI
import PalaceBookModel
import PalaceUtilities

/// Carrier box that lets a read-only `[TPPBook]` snapshot cross into a
/// `@Sendable` detached prefetch task. `TPPBook` is a non-Sendable
/// `NSObject`; the boxed array is never mutated after construction and is
/// consumed by exactly one detached task (read-only thumbnail fetch), so
/// `@unchecked Sendable` is sound. Mirrors the carrier-box precedent
/// (`CarPlayImageCompletionBox`, `ReadiumBookmarkBox`).
private final class PrefetchBooksBox: @unchecked Sendable {
    let books: [TPPBook]
    init(_ books: [TPPBook]) { self.books = books }
}

/// Carrier box that lets the `ImageLoading` reference cross into the
/// `@Sendable` detached prefetch task. `ImageLoading` is a class-bound
/// (`AnyObject`) protocol not yet annotated `Sendable`; the boxed reference is
/// read-only (only `thumbnailImage(for:)` is called, whose own implementation
/// is internally synchronized), consumed by exactly one detached task, so
/// `@unchecked Sendable` is sound. Removable once `ImageLoading` is made
/// `Sendable` upstream (tracked in RIPPLES.md). Mirrors `PrefetchBooksBox`.
private final class PrefetchImageLoaderBox: @unchecked Sendable {
    let loader: ImageLoading
    init(_ loader: ImageLoading) { self.loader = loader }
}

struct BookListView: View {
    let books: [TPPBook]
    @Binding var isLoading: Bool
    let onSelect: (TPPBook) -> Void
    var onLoadMore: (() async -> Void)?
    var isLoadingMore: Bool = false
    var previewEnabled: Bool = true
    @State private var containerWidth: CGFloat = UIScreen.main.bounds.width

    /// Shared model cache for performance - reuses BookCellModel instances
    @Environment(\.appContainer) private var appContainer
    private var modelCache: BookCellModelCache { appContainer.bookCellModelCache }

    /// Number of items to prefetch beyond visible range.
    /// Kept low to avoid memory pressure from concurrent image decodes
    /// when browsing catalogs with many entries (e.g., Stanislaus County PP-3682).
    private let prefetchBuffer = 4

    var body: some View {
        LazyVGrid(columns: gridLayout, spacing: 0) {
            ForEach(books, id: \.identifier) { book in
                // PP-4326: just wrap the cell in a SwiftUI Button with a
                // custom voiceOverLabel + hint. Let SwiftUI's natural
                // accessibility do the rest — the outer Button is the
                // "tap anywhere on the row" element, and the inner action
                // Buttons inside BookButtonsView surface as separate
                // accessibility elements (because they're real SwiftUI
                // Buttons with their own labels). iOS routes a VoiceOver
                // tap to the topmost accessibility element at the tap
                // location: tap on Borrow → Borrow is the topmost there
                // and gets focus; tap on cover/title → no inner Button at
                // that location, the outer row Button gets focus. PP-3968
                // broke this by adding .accessibilityElement(children:
                // .ignore), which collapsed the cell into one element and
                // hid the inner buttons. Just don't do that.
                Button(action: { onSelect(book) }, label: {
                    BookCell(model: modelCache.model(for: book), previewEnabled: previewEnabled)
                })
                .buttonStyle(.palacePressable)
                .applyBorderStyle()
                .accessibilityLabel(book.voiceOverLabel)
                .accessibilityHint(Strings.Accessibility.opensBookDetails)
                .accessibilityIdentifier(AccessibilityID.BookList.cell(book.identifier))
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
                    }
                    .onChange(of: geometry.size.width) { _, newWidth in
                        containerWidth = newWidth
                    }
            }
        )
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

        // Route through the injected ImageLoading umbrella so prefetch shares
        // the AppContainer-owned cache + circuit breaker rather than reaching
        // for TPPBookCoverRegistry.shared. Capture the value to avoid touching
        // the SwiftUI Environment from the detached task.
        // `TPPBook` is a non-Sendable `NSObject` and `ImageLoading` is a
        // class-bound protocol not yet annotated `Sendable`, so neither
        // `[TPPBook]` nor the loader can cross into the `@Sendable` detached
        // task under `complete`-mode strict concurrency. Wrap both in carrier
        // boxes: the array is a read-only snapshot and the loader reference is
        // read-only (thumbnail fetch only), each handed to a single detached
        // task — never mutated, never shared with another consumer — so
        // `@unchecked Sendable` is sound. (Precedent: `CarPlayImageCompletionBox`,
        // `ReadiumBookmarkBox`.)
        let upcomingBooksBox = PrefetchBooksBox(upcomingBooks)
        let imageLoaderBox = PrefetchImageLoaderBox(appContainer.imageLoader)
        Task.detached(priority: .utility) {
            for book in upcomingBooksBox.books {
                _ = await imageLoaderBox.loader.thumbnailImage(for: book)
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

    private var gridLayout: [GridItem] {
        let count = Self.columnCount(
            forContainerWidth: containerWidth,
            isIPad: UIDevice.current.userInterfaceIdiom == .pad
        )
        return Array(repeating: GridItem(.flexible(), spacing: 0), count: count)
    }

    /// Columns for the width the grid is actually given.
    ///
    /// This used to read `UIScreen.main.bounds` and compare width to height,
    /// refreshed on appear and on `UIDevice.orientationDidChangeNotification`.
    /// iOS delivers that notification only after
    /// `beginGeneratingDeviceOrientationNotifications()`, which this app does not
    /// call, so the count was pinned to whatever the screen was when the view
    /// first appeared. The container's own width needs no notification at all,
    /// and is also right in Split View, which no screen-level signal reports. An iPad Pro 12.9 in portrait rendered the landscape
    /// count, leaving each cell 341pt: due dates wrapped onto four lines and
    /// titles truncated.
    ///
    /// The container's own width is right on rotation and also right in Split
    /// View, Slide Over and Stage Manager, where the screen's bounds describe
    /// a window the grid does not have.
    ///
    /// 360pt is the floor per column. The defect rendered at 341pt, and 360 is
    /// the first value above it that still yields the counts every shipping
    /// iPad already used — 2 up to the 12.9's 1024pt portrait, 3 from the
    /// 10.2's 1080pt landscape. The cap keeps an external display or a wider
    /// future iPad from shredding the cells.
    static func columnCount(forContainerWidth width: CGFloat, isIPad: Bool) -> Int {
        guard isIPad else { return 1 }
        let fits = Int((width / 360).rounded(.down))
        return min(max(fits, 1), 3)
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
