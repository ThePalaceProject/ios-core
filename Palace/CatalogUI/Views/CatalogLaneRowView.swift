import SwiftUI

struct CatalogLaneRowView: View {
  let title: String
  let books: [TPPBook]
  let moreURL: URL?
  let onSelect: (TPPBook) -> Void
  var showHeader: Bool = true

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      if showHeader {
        Self.header(title: title, moreURL: moreURL)
          .padding(.horizontal, 12)
      }
      scroller
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
        }
      }
      .padding(.horizontal, 12)
    }
  }

  @ViewBuilder
  static func header(title: String, moreURL: URL?) -> some View {
    HStack(alignment: .bottom) {
      Text(title)
        .font(.title2)
        .lineLimit(3)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
      Spacer()
      if let more = moreURL {
        NavigationLink("More…", destination: CatalogLaneMoreView(title: title, url: more))
          .font(.footnote)
      }
    }
  }
}


