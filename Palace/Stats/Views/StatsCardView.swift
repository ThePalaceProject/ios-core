import SwiftUI

/// A reusable card displaying a single stat with icon, value, and label.
struct StatsCardView: View {
  let iconName: String
  let value: String
  let label: String
  var iconColor: Color = .accentColor

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: iconName)
        .font(.title2)
        .foregroundStyle(iconColor)
        .accessibilityHidden(true)

      Text(value)
        .font(.title2)
        .fontWeight(.bold)
        .minimumScaleFactor(0.7)
        .lineLimit(1)

      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding()
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(label): \(value)")
  }
}

#Preview {
  HStack {
    StatsCardView(iconName: "book.fill", value: "12", label: "Books Finished")
    StatsCardView(iconName: "clock.fill", value: "48h", label: "Total Time", iconColor: .orange)
  }
  .padding()
}
