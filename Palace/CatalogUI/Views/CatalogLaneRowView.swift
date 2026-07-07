import SwiftUI

struct CatalogLaneRowView: View {
    let title: String
    let books: [TPPBook]
    let moreURL: URL?
    let onSelect: (TPPBook) -> Void
    let onMoreTapped: ((String, URL) -> Void)?
    var showHeader: Bool = true
    var isLoading: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showHeader {
                Self.header(title: title, moreURL: moreURL, onMoreTapped: onMoreTapped)
                    .padding(.horizontal, 12)
            }

            if isLoading || books.isEmpty {
                laneSkeletonScroller
            } else {
                scroller
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var scroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(books, id: \.identifier) { book in
                    Button(action: { onSelect(book) }, label: {
                        BookImageView(
                            book: book,
                            width: nil,
                            height: 150,
                            usePulseSkeleton: true,
                            treatImageAsDecorativeInLists: true
                        )
                        .adaptiveShadow(radius: 4)
                        .padding(.vertical)
                    })
                    .buttonStyle(.palacePressable)
                    // lift the cover when a pointer (iPad pencil/mouse
                    // or iPad-on-Mac mouse) hovers it. No-op on touch-only iPhones.
                    .hoverEffect(.lift)
                    .accessibilityLabel(Self.accessibilityLabel(for: book))
                }
            }
            .padding(.horizontal, 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader) // scroll container exposes title in heading rotor
        .accessibilityValue(Strings.SearchAnnouncements.searchResultsListValue(bookCount: books.count))
        .accessibilityHint(Strings.Generic.horizontalLaneHint)
    }

    /// Single source of truth for the catalog cell VoiceOver label.
    /// Delegates to TPPBook.voiceOverLabel for the canonical Audible/Libby-style format.
    static func accessibilityLabel(for book: TPPBook) -> String {
        book.voiceOverLabel
    }

    @ViewBuilder
    private var laneSkeletonScroller: some View {
        LaneSkeletonView()
    }

    @ViewBuilder
    static func header(title: String, moreURL: URL?, onMoreTapped: ((String, URL) -> Void)?) -> some View {
        HStack(alignment: .bottom) {
            Text(title)
                .font(.title2)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader) // expose swimlane title in heading rotor
            Spacer()
            if let more = moreURL, let onMoreTapped = onMoreTapped {
                Button("More…") {
                    onMoreTapped(title, more)
                }
                .font(.footnote)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel(String(format: Strings.Generic.moreBooksInLane, title))
            }
        }
    }
}

// MARK: - Lane Skeleton View
private struct LaneSkeletonView: View {
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(0..<6, id: \.self) { _ in
                    Rectangle()
                        .fill(Color.gray.opacity(0.25))
                        .frame(width: 100, height: 150)
                        .shimmerEffect()
                        .padding(.vertical)
                }
            }
            .padding(.horizontal, 12)
        }
    }
}
