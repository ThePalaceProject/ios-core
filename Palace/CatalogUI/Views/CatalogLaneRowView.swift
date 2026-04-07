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
                    .buttonStyle(.plain)
                    // PP-3968: replace the children with a single, predictable
                    // VoiceOver announcement (Title, by Author, narrated by …)
                    // and drop the "button" trait so the cell sounds like a
                    // static list item — matches Audible/Libby UX.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.accessibilityLabel(for: book))
                    .accessibilityRemoveTraits(.isButton)
                }
            }
            .padding(.horizontal, 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(Strings.SearchAnnouncements.searchResultsListValue(bookCount: books.count))
        .accessibilityHint(Strings.Generic.horizontalLaneHint)
        .accessibilityAddTraits(.isHeader)
    }

    /// PP-3968: Build a single, predictable VoiceOver label per book cell.
    /// Mirrors how Audible/Libby announce a list item:
    ///
    ///   • Ebook with author:           "Title, by Author"
    ///   • Ebook without author:        "Title"
    ///   • Audiobook with narrator:     "Title, by Author, narrated by Narrator"
    ///   • Audiobook, no author:        "Title, narrated by Narrator"
    ///   • Audiobook, no narrator:      "Title, audiobook, by Author"
    ///   • Audiobook, neither:          "Title, audiobook"
    ///
    /// Static so the unit tests can call it without instantiating the view.
    static func accessibilityLabel(for book: TPPBook) -> String {
        let title = book.title
        let author = book.authors?.trimmingCharacters(in: .whitespacesAndNewlines)
        let narrator = book.narrators?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAuthor = !(author?.isEmpty ?? true)
        let hasNarrator = !(narrator?.isEmpty ?? true)

        if book.isAudiobook {
            switch (hasAuthor, hasNarrator) {
            case (true, true):
                return Strings.Generic.audiobookByAuthorNarratedBy(title: title, author: author!, narrator: narrator!)
            case (true, false):
                return Strings.Generic.audiobookByAuthor(title: title, author: author!)
            case (false, true):
                return Strings.Generic.audiobookNarratedBy(title: title, narrator: narrator!)
            case (false, false):
                return "\(title), \(Strings.Generic.audiobook)"
            }
        }

        if hasAuthor {
            return Strings.Generic.bookByAuthor(title: title, author: author!)
        }
        return title
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
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let more = moreURL, let onMoreTapped = onMoreTapped {
                Button("More…") {
                    onMoreTapped(title, more)
                }
                .font(.footnote)
                .accessibilityLabel(String(format: Strings.Generic.moreBooksInLane, title))
            }
        }
    }
}

// MARK: - Lane Skeleton View
private struct LaneSkeletonView: View {
    @State private var pulse: Bool = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(0..<6, id: \.self) { _ in
                    Rectangle()
                        .fill(Color.gray.opacity(0.25))
                        .frame(width: 120, height: 150)
                        .opacity(pulse ? 0.6 : 1.0)
                        .padding(.vertical)
                }
            }
            .padding(.horizontal, 12)
        }
        .onAppear {
            accessibleWithAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
