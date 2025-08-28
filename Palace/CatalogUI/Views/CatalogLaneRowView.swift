import SwiftUI

struct CatalogLaneRowView: View {
  let title: String
  let books: [TPPBook]
  let moreURL: URL?
  let onSelect: (TPPBook) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(title).font(.title3).bold()
        Spacer()
        if let more = moreURL {
          NavigationLink("More…", destination: CatalogLaneMoreView(title: title, url: more))
        }
      }
      .padding(.horizontal, 12)

      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 12) {
          ForEach(books, id: \.identifier) { book in
            Button(action: { onSelect(book) }) {
              BookImageView(book: book, width: nil, height: 180, usePulseSkeleton: true)
                .adaptiveShadowLight(radius: 1.5)
                .padding(.vertical)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 12)
      }
    }
  }
}


