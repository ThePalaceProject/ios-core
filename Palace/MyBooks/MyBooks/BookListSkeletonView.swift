import SwiftUI

// MARK: - BookRowSkeletonView

struct BookRowSkeletonView: View {
  var imageSize: CGSize = .init(width: 100, height: 150)
  @State private var pulse: Bool = false
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.gray.opacity(0.25))
        .frame(width: imageSize.width, height: imageSize.height)
        .opacity(pulse ? 0.6 : 1.0)

      VStack(alignment: .leading, spacing: 10) {
        RoundedRectangle(cornerRadius: 4)
          .fill(Color.gray.opacity(0.25))
          .frame(width: 180, height: 14)
          .opacity(pulse ? 0.6 : 1.0)

        RoundedRectangle(cornerRadius: 4)
          .fill(Color.gray.opacity(0.25))
          .frame(width: 120, height: 12)
          .opacity(pulse ? 0.6 : 1.0)
      }
      Spacer()
    }
    .padding(5)
    .overlay(
      Rectangle()
        .frame(height: 1)
        .foregroundColor(Color.gray.opacity(0.5))
        .offset(y: 0.5),
      alignment: .bottom
    )
    .onAppear {
      withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
        pulse = true
      }
    }
  }
}

// MARK: - BookListSkeletonView

struct BookListSkeletonView: View {
  var rows: Int = 8
  var imageSize: CGSize = .init(width: 100, height: 150)

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        ForEach(0..<rows, id: \.self) { _ in
          BookRowSkeletonView(imageSize: imageSize)
        }
      }
      .padding()
    }
  }
}
