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
            BookCell(model: BookCellModel(book: book))
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
    Array(repeating: GridItem(.fixed(columnWidth), spacing: 0), count: columnCount)
  }

  private var columnCount: Int {
    UIDevice.current.userInterfaceIdiom == .pad ? (orientation.isLandscape ? 4 : 3) : 1
  }

  private var columnWidth: CGFloat {
    UIScreen.main.bounds.width / CGFloat(columnCount) - (UIDevice.current.isIpad ? 8 : 0)
  }
}
extension View {
  func applyBorderStyle() -> some View {
    modifier(BorderStyleModifier())
  }
}

