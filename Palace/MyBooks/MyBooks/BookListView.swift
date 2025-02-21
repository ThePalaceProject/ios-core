import SwiftUI

struct BookListView: View {
  let books: [TPPBook]
  @Binding var isLoading: Bool
  let onSelect: (TPPBook) -> Void

  var body: some View {
    ScrollView {
      LazyVGrid(columns: gridLayout, spacing: 0) {
        ForEach(books, id: \.identifier) { book in
          Button(action: { onSelect(book) }) {
            BookCell(model: BookCellModel(book: book))
              .frame(height: 170)
              .applyBorderStyle()
          }
          .buttonStyle(.plain)
        }
      }
      .padding()
    }
  }

  private var gridLayout: [GridItem] {
    UIDevice.current.isIpad
    ? [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
    : [GridItem(.flexible())]
  }
}

extension View {
  func applyBorderStyle() -> some View {
    if UIDevice.current.isIpad {
      return self.overlay(
        Rectangle()
          .stroke(Color.gray.opacity(0.5), lineWidth: 2)
      )
      .anyView()
    } else {
      return self.overlay(
        Rectangle()
          .frame(height: 1)
          .foregroundColor(Color.gray.opacity(0.5))
          .offset(y: 0.5),
        alignment: .bottom
      )
      .anyView()
    }
  }
}
