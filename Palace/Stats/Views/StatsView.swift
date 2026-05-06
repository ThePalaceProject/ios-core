import SwiftUI

/// Main stats tab showing streak, reading chart, key stats, and recent badges.
@available(iOS 16.0, *)
struct StatsView: View {
  @ObservedObject var viewModel: StatsViewModel
  let badgesViewModel: BadgesViewModel

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 16) {
          streakSection
          timePeriodPicker
          chartSection
          statsGrid
          recentBadgesSection
        }
        .padding()
      }
      .navigationTitle("Reading Stats")
      .navigationBarTitleDisplayMode(.large)
      .refreshable {
        await viewModel.load()
      }
      .task {
        await viewModel.load()
      }
    }
  }

  // MARK: - Streak

  @ViewBuilder
  private var streakSection: some View {
    HStack(spacing: 16) {
      HStack(spacing: 8) {
        if viewModel.currentStreak.currentStreakDays > 0 {
          Image(systemName: "flame.fill")
            .font(.title)
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
        } else {
          Image(systemName: "flame")
            .font(.title)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }

        VStack(alignment: .leading, spacing: 2) {
          Text(viewModel.streakDisplayText)
            .font(.title2)
            .fontWeight(.bold)
          Text(viewModel.longestStreakText)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Reading streak: \(viewModel.streakDisplayText). \(viewModel.longestStreakText)")

      Spacer()

      NavigationLink {
        ScrollView {
          StreakView(streak: viewModel.currentStreak)
            .padding()
        }
        .navigationTitle("Streak Details")
        .navigationBarTitleDisplayMode(.inline)
      } label: {
        Text("Details")
          .font(.subheadline)
          .foregroundColor(.accentColor)
      }
    }
    .padding()
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }

  // MARK: - Time Period Picker

  @ViewBuilder
  private var timePeriodPicker: some View {
    Picker("Time Period", selection: $viewModel.selectedTimePeriod) {
      ForEach(TimePeriod.allCases) { period in
        Text(period.rawValue).tag(period)
      }
    }
    .pickerStyle(.segmented)
  }

  // MARK: - Chart

  @ViewBuilder
  private var chartSection: some View {
    ReadingChartView(
      dataPoints: viewModel.chartData,
      timePeriod: viewModel.selectedTimePeriod
    )
  }

  // MARK: - Stats Grid

  @ViewBuilder
  private var statsGrid: some View {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
      StatsCardView(
        iconName: "book.fill",
        value: "\(viewModel.stats.totalBooksFinished)",
        label: "Books Finished",
        iconColor: .blue
      )
      StatsCardView(
        iconName: "clock.fill",
        value: viewModel.stats.formattedTotalTime,
        label: "Total Time",
        iconColor: .orange
      )
      StatsCardView(
        iconName: "doc.text.fill",
        value: "\(viewModel.stats.totalPagesRead)",
        label: "Pages Read",
        iconColor: .green
      )
      StatsCardView(
        iconName: "flame.fill",
        value: "\(viewModel.currentStreak.currentStreakDays)",
        label: "Day Streak",
        iconColor: .red
      )
    }
  }

  // MARK: - Recent Badges

  @ViewBuilder
  private var recentBadgesSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Recent Badges")
          .font(.headline)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        NavigationLink {
          BadgesView(viewModel: badgesViewModel)
        } label: {
          Text("View All")
            .font(.subheadline)
        }
      }

      if viewModel.recentBadges.isEmpty {
        HStack {
          Spacer()
          VStack(spacing: 8) {
            Image(systemName: "star.fill")
              .font(.title)
              .foregroundStyle(.secondary.opacity(0.5))
            Text("No badges earned yet")
              .font(.subheadline)
              .foregroundStyle(.secondary)
            Text("Keep reading to earn achievements!")
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
          .padding(.vertical)
          Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No badges earned yet. Keep reading to earn achievements.")
      } else {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 16) {
            ForEach(viewModel.recentBadges) { badge in
              recentBadgeCell(badge)
            }
          }
        }
      }
    }
    .padding()
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }

  @ViewBuilder
  private func recentBadgeCell(_ badge: Badge) -> some View {
    VStack(spacing: 6) {
      ZStack {
        Circle()
          .fill(tierGradient(for: badge.tier))
          .frame(width: 56, height: 56)
        Image(systemName: badge.iconName)
          .font(.title3)
          .foregroundStyle(.white)
      }
      Text(badge.name)
        .font(.caption2)
        .fontWeight(.medium)
        .lineLimit(2)
        .multilineTextAlignment(.center)
        .frame(width: 70)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(badge.name) badge, \(badge.tier.rawValue) tier")
  }

  private func tierGradient(for tier: BadgeTier) -> LinearGradient {
    switch tier {
    case .bronze:
      return LinearGradient(colors: [Color(red: 0.8, green: 0.5, blue: 0.2), Color(red: 0.6, green: 0.35, blue: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
    case .silver:
      return LinearGradient(colors: [Color.gray.opacity(0.8), Color.gray.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
    case .gold:
      return LinearGradient(colors: [Color.yellow, Color.orange], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
  }
}
