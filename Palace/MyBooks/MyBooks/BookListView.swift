import SwiftUI

struct BookListView: View {
  let books: [TPPBook]
  @Binding var isLoading: Bool
  let onSelect: (TPPBook) -> Void
  @State private var containerWidth: CGFloat = UIScreen.main.bounds.width

  var body: some View {
    ScrollView {
      LazyVGrid(columns: gridLayout, spacing: 0) {
        ForEach(books, id: \.identifier) { book in
          Button(action: { onSelect(book) }) {
            BookCell(model: BookCellModel(book: book, imageCache: ImageCache.shared))
          }
          .buttonStyle(.plain)
          .applyBorderStyle()
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
            .onChange(of: geometry.size.width) { newWidth in
              containerWidth = newWidth
            }
        }
      )
    }
    .dismissKeyboardOnTap()
  }

  private var gridLayout: [GridItem] {
    if UIDevice.current.userInterfaceIdiom == .pad {
      let isLandscape = containerWidth > containerWidth * 0.8 // Simple heuristic
      let screenWidth = UIScreen.main.bounds.width
      let screenHeight = UIScreen.main.bounds.height
      let actualIsLandscape = screenWidth > screenHeight
      
      let columnCount = actualIsLandscape ? 3 : 2
      return Array(repeating: GridItem(.flexible(), spacing: 0), count: columnCount)
    } else {
      return [GridItem(.adaptive(minimum: 220), spacing: 0)]
    }
  }
}

extension View {
  func applyBorderStyle() -> some View {
    modifier(BorderStyleModifier())
  }
}

