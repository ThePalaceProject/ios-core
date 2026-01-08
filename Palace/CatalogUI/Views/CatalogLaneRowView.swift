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
          Button(action: { onSelect(book) }) {
            BookImageView(
              book: book,
              width: nil,
              height: 150,
              usePulseSkeleton: true
            )
              .padding(.vertical)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(accessibilityLabel(for: book))
        }
      }
      .padding(.horizontal, 12)
    }
  }
  
  private func accessibilityLabel(for book: TPPBook) -> String {
    var components = [book.title]
    if book.isAudiobook {
      components.append(Strings.Generic.audiobook)
    }
    if let authors = book.authors, !authors.isEmpty {
      components.append(authors)
    }
    return components.joined(separator: ", ")
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
      Spacer()
      if let more = moreURL, let onMoreTapped = onMoreTapped {
        Button("More…") {
          onMoreTapped(title, more)
        }
        .font(.footnote)
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
      withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
        pulse = true
      }
    }
  }
}


