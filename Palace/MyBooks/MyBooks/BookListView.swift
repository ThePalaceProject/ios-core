import SwiftUI

struct BookListView: View {
  let books: [TPPBook]
  @Binding var isLoading: Bool
  let onSelect: (TPPBook) -> Void
  @StateObject private var orientation = DeviceOrientation()

  var body: some View {
    ScrollView {
      LazyVGrid(columns: gridLayout, spacing: 0) {
        ForEach(books, id: \.identifier) { book in
          Button(action: { onSelect(book) }) {
            BookCell(model: BookCellModel(book: book, imageCache: ImageCache.shared))
              .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 180)
          }
          .buttonStyle(.plain)
          .padding(5)
          .applyBorderStyle()
        }
      }
      .padding()
      .onAppear {
        orientation.startTracking()
      }
      .onDisappear {
        orientation.stopTracking()
      }
    }
  }

  private var gridLayout: [GridItem] {
    [GridItem(.adaptive(minimum: minColumnWidth), spacing: 0)]
  }

  private var minColumnWidth: CGFloat {
    UIDevice.current.userInterfaceIdiom == .pad ? 320 : 300
  }
}

extension View {
  func applyBorderStyle() -> some View {
    modifier(BorderStyleModifier())
  }
}

