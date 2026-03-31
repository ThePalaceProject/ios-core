import SwiftUI

/// Entry point for the Stats tab, ready to plug into the main tab bar.
/// Constructs the service graph and passes dependencies to child views.
/// Gated by `RemoteFeatureFlags.FeatureFlag.readingStatsEnabled`.
@available(iOS 16.0, *)
struct StatsTab: View {
  /// Whether the Reading Stats feature is enabled.
  static var isEnabled: Bool {
      RemoteFeatureFlags.shared.isFeatureEnabled(.readingStatsEnabled)
  }

  private let statsService: ReadingStatsServiceProtocol
  private let badgeService: BadgeServiceProtocol
  @StateObject private var statsViewModel: StatsViewModel
  @StateObject private var badgesViewModel: BadgesViewModel

  /// Initialize with explicit dependencies (for DI / testing).
  init(statsService: ReadingStatsServiceProtocol, badgeService: BadgeServiceProtocol) {
    self.statsService = statsService
    self.badgeService = badgeService
    _statsViewModel = StateObject(wrappedValue: StatsViewModel(statsService: statsService, badgeService: badgeService))
    _badgesViewModel = StateObject(wrappedValue: BadgesViewModel(badgeService: badgeService))
  }

  /// Convenience initializer that creates default services with local persistence.
  init() {
    let store = ReadingStatsStore()
    let stats = ReadingStatsService(store: store)
    let badges = BadgeService(statsService: stats, store: store)
    self.init(statsService: stats, badgeService: badges)
  }

  var body: some View {
    StatsView(viewModel: statsViewModel, badgesViewModel: badgesViewModel)
  }
}

#Preview {
  StatsTab()
}
