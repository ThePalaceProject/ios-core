import SwiftUI

/// Detail popover shown when tapping a badge.
@available(iOS 16.0, *)
struct BadgeDetailView: View {
  let badge: Badge
  let hint: String?

  init(badge: Badge, hint: String? = nil) {
    self.badge = badge
    self.hint = hint ?? BadgeCatalog.all.first(where: { $0.id == badge.id })?.hint
  }

  var body: some View {
    VStack(spacing: 20) {
      badgeIcon
      badgeInfo
      progressSection
      if let hint, !badge.isEarned {
        hintSection(hint)
      }
    }
    .padding(24)
    .frame(maxWidth: 320)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 20))
    .shadow(radius: 10)
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private var badgeIcon: some View {
    ZStack {
      Circle()
        .fill(tierGradient)
        .frame(width: 80, height: 80)

      if badge.isEarned {
        Image(systemName: badge.iconName)
          .font(.system(size: 36))
          .foregroundStyle(.white)
      } else {
        Image(systemName: "questionmark")
          .font(.system(size: 36))
          .foregroundStyle(.white.opacity(0.5))
      }
    }
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private var badgeInfo: some View {
    VStack(spacing: 6) {
      Text(badge.name)
        .font(.title3)
        .fontWeight(.bold)
        .multilineTextAlignment(.center)

      Text(tierLabel)
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(tierColor)
        .textCase(.uppercase)

      Text(badge.descriptionText)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      if let earnedDate = badge.earnedDate {
        Text("Earned \(earnedDate, style: .date)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var progressSection: some View {
    if !badge.isEarned {
      VStack(spacing: 6) {
        ProgressView(value: badge.progress)
          .tint(tierColor)

        Text("\(badge.progressPercentage)% complete")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private func hintSection(_ hint: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "lightbulb.fill")
        .foregroundStyle(.yellow)
        .font(.caption)
      Text(hint)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(12)
    .background(Color.yellow.opacity(0.1))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private var tierGradient: LinearGradient {
    switch badge.tier {
    case .bronze:
      return LinearGradient(colors: [Color(red: 0.8, green: 0.5, blue: 0.2), Color(red: 0.6, green: 0.35, blue: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
    case .silver:
      return LinearGradient(colors: [Color.gray.opacity(0.8), Color.gray.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
    case .gold:
      return LinearGradient(colors: [Color.yellow, Color.orange], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
  }

  private var tierColor: Color {
    switch badge.tier {
    case .bronze: return Color(red: 0.8, green: 0.5, blue: 0.2)
    case .silver: return .gray
    case .gold: return .orange
    }
  }

  private var tierLabel: String {
    badge.tier.rawValue.capitalized
  }
}

#Preview {
  BadgeDetailView(
    badge: Badge(
      id: "test",
      name: "Streak Master",
      descriptionText: "Maintained a 7-day reading streak.",
      iconName: "flame.fill",
      tier: .bronze,
      progress: 0.7
    ),
    hint: "Read every day for a week straight."
  )
}
