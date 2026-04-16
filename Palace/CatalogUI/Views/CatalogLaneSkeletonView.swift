import SwiftUI

/// Skeleton placeholder matching the exact layout of CatalogLaneRowView.
///
/// Measured from live element positions (SpecterQA):
/// - Title: 26pt height, left-aligned at x=12
/// - Books: 100×150pt, 12pt spacing, starts 12pt from left edge
/// - VStack spacing between title and books: 5pt
/// - Vertical padding around book scroller: inherits from .padding(.vertical)
struct CatalogLaneSkeletonView: View {
    var itemCount: Int = 6
    @State private var pulse: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Rectangle()
                .fill(Color.gray.opacity(0.25))
                .frame(width: 200, height: 26)
                .opacity(pulse ? 0.6 : 1.0)
                .padding(.horizontal, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(0..<itemCount, id: \.self) { _ in
                        Rectangle()
                            .fill(Color.gray.opacity(0.25))
                            .frame(width: 100, height: 150)
                            .opacity(pulse ? 0.6 : 1.0)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical)
            }
        }
        .onAppear {
            accessibleWithAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
