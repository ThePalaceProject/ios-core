import SwiftUI

struct BookListView: View {
  let books: [TPPBook]
  @Binding var isLoading: Bool
  let onSelect: (TPPBook) -> Void
  var onLoadMore: (() async -> Void)? = nil
  var isLoadingMore: Bool = false
  var previewEnabled: Bool = true
  @State private var containerWidth: CGFloat = UIScreen.main.bounds.width
  @State private var screenSize: CGSize = UIScreen.main.bounds.size

  var body: some View {
    LazyVGrid(columns: gridLayout, spacing: 0) {
      ForEach(books, id: \.identifier) { book in
        Button(action: { onSelect(book) }) {
          BookCell(model: BookCellModel(book: book, imageCache: ImageCache.shared), previewEnabled: previewEnabled)
        }
        .buttonStyle(.plain)
        .applyBorderStyle()
        .onAppear {
          if let onLoadMore = onLoadMore, book.identifier == books.last?.identifier {
            Task { await onLoadMore() }
          }
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
            screenSize = UIScreen.main.bounds.size
          }
          .onChange(of: geometry.size.width) { newWidth in
            containerWidth = newWidth
          }
      }
    )
    .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
      screenSize = UIScreen.main.bounds.size
    }
  }
  
  private var paginationLoadingIndicator: some View {
    PulsatingDotsLoader()
      .frame(maxWidth: .infinity)
      .padding(.vertical, 24)
      .gridCellColumns(gridLayout.count)
  }

  private var gridLayout: [GridItem] {
    let isLandscape = screenSize.width > screenSize.height
    let isIPad = UIDevice.current.userInterfaceIdiom == .pad
    
    if isIPad {
      let columnCount = isLandscape ? 3 : 2
      return Array(repeating: GridItem(.flexible(), spacing: 0), count: columnCount)
    } else {
      return [GridItem(.flexible(), spacing: 0)]
    }
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
      withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
        pulse1 = true
      }
      withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true).delay(0.3)) {
        pulse2 = true
      }
      withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true).delay(0.6)) {
        pulse3 = true
      }
    }
  }
}

