import SwiftUI

/// Full badge collection grid showing earned, in-progress, and locked badges.
@available(iOS 16.0, *)
struct BadgesView: View {
  @ObservedObject var viewModel: BadgesViewModel

  private let columns = [
    GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 16)
  ]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        headerSection
        if !viewModel.earnedBadges.isEmpty {
          badgeSection(title: "Earned", badges: viewModel.earnedBadges)
        }
        if !viewModel.inProgressBadges.isEmpty {
          badgeSection(title: "In Progress", badges: viewModel.inProgressBadges)
        }
        if !viewModel.lockedBadges.isEmpty {
          badgeSection(title: "Locked", badges: viewModel.lockedBadges)
        }
      }
      .padding()
    }
    .navigationTitle("Badges")
    .navigationBarTitleDisplayMode(.large)
    .sheet(isPresented: $viewModel.showBadgeDetail) {
      if let badge = viewModel.selectedBadge {
        BadgeDetailView(badge: badge)
          .presentationDetents([.medium])
          .presentationDragIndicator(.visible)
      }
    }
    .task {
      await viewModel.load()
    }
  }

  @ViewBuilder
  private var headerSection: some View {
    VStack(spacing: 4) {
      Text(viewModel.progressSummary)
        .font(.subheadline)
        .foregroundStyle(.secondary)

      ProgressView(value: Double(viewModel.earnedCount), total: Double(viewModel.totalBadgesCount))
        .tint(.accentColor)
    }
  }

  @ViewBuilder
  private func badgeSection(title: String, badges: [Badge]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.title3)
        .fontWeight(.semibold)
        .accessibilityAddTraits(.isHeader)

      LazyVGrid(columns: columns, spacing: 16) {
        ForEach(badges) { badge in
          BadgeGridCell(
            badge: badge,
            isNewlyEarned: viewModel.newlyEarnedBadgeIDs.contains(badge.id)
          )
          .onTapGesture {
            viewModel.selectBadge(badge)
          }
          .accessibilityAddTraits(.isButton)
        }
      }
    }
  }
}

/// A single cell in the badge grid.
@available(iOS 16.0, *)
private struct BadgeGridCell: View {
  let badge: Badge
  let isNewlyEarned: Bool

  @State private var animateUnlock = false

  var body: some View {
    VStack(spacing: 8) {
      ZStack {
        Circle()
          .fill(backgroundFill)
          .frame(width: 64, height: 64)

        if badge.isEarned {
          Image(systemName: badge.iconName)
            .font(.title2)
            .foregroundStyle(.white)
        } else if badge.isInProgress {
          ZStack {
            Circle()
              .trim(from: 0, to: badge.progress)
              .stroke(progressColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
              .frame(width: 64, height: 64)
              .rotationEffect(.degrees(-90))
            Image(systemName: badge.iconName)
              .font(.title3)
              .foregroundStyle(.secondary)
          }
        } else {
          Image(systemName: "questionmark")
            .font(.title2)
            .foregroundStyle(.secondary.opacity(0.5))
        }
      }
      .scaleEffect(animateUnlock ? 1.2 : 1.0)
      .animation(.spring(response: 0.5, dampingFraction: 0.5), value: animateUnlock)

      Text(badge.isEarned || badge.isInProgress ? badge.name : "???")
        .font(.caption2)
        .fontWeight(.medium)
        .lineLimit(2)
        .multilineTextAlignment(.center)
        .foregroundStyle(badge.isEarned ? .primary : .secondary)

      if badge.isInProgress {
        Text("\(badge.progressPercentage)%")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
      } else if badge.isEarned, let date = badge.earnedDate {
        Text(date, style: .date)
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .onChange(of: isNewlyEarned) { newValue in
      if newValue {
        withAnimation {
          animateUnlock = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          withAnimation { animateUnlock = false }
        }
      }
    }
  }

  private var backgroundFill: some ShapeStyle {
    if badge.isEarned {
      return AnyShapeStyle(tierGradient)
    } else {
      return AnyShapeStyle(Color.secondary.opacity(0.15))
    }
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

  private var progressColor: Color {
    switch badge.tier {
    case .bronze: return Color(red: 0.8, green: 0.5, blue: 0.2)
    case .silver: return .gray
    case .gold: return .orange
    }
  }

  private var accessibilityLabel: String {
    if badge.isEarned {
      return "\(badge.name), earned, \(badge.tier.rawValue) tier"
    } else if badge.isInProgress {
      return "\(badge.name), \(badge.progressPercentage) percent complete, \(badge.tier.rawValue) tier"
    } else {
      return "Locked badge, tap for hint"
    }
  }
}

#Preview {
  NavigationStack {
    BadgesView(viewModel: {
      let vm = BadgesViewModel(badgeService: PreviewBadgeService())
      return vm
    }())
  }
}

// MARK: - Preview Helper

private actor PreviewBadgeService: BadgeServiceProtocol {
  func evaluateAllBadges() -> [Badge] { [] }
  func earnedBadges() -> [Badge] {
    [Badge(id: "1", name: "First Chapter", descriptionText: "Finished your first book", iconName: "book.closed.fill", tier: .bronze, earnedDate: Date())]
  }
  func inProgressBadges() -> [Badge] {
    [Badge(id: "2", name: "10 Books Club", descriptionText: "Finish 10 books", iconName: "books.vertical.fill", tier: .bronze, progress: 0.6)]
  }
  func lockedBadges() -> [Badge] {
    [Badge(id: "3", name: "Speed Reader", descriptionText: "Finish a book in one day", iconName: "hare.fill", tier: .silver)]
  }
  func refresh() {}
}
