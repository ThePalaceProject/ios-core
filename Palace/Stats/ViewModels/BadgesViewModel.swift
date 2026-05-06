import Foundation
import Combine

/// ViewModel for the badge collection screen.
@MainActor
final class BadgesViewModel: ObservableObject {
  @Published private(set) var earnedBadges: [Badge] = []
  @Published private(set) var inProgressBadges: [Badge] = []
  @Published private(set) var lockedBadges: [Badge] = []
  @Published private(set) var isLoading = false
  @Published var selectedBadge: Badge?
  @Published var showBadgeDetail = false

  /// Tracks newly earned badge IDs for animation.
  @Published var newlyEarnedBadgeIDs: Set<String> = []

  private let badgeService: BadgeServiceProtocol
  private var cancellables = Set<AnyCancellable>()

  init(badgeService: BadgeServiceProtocol) {
    self.badgeService = badgeService

    NotificationCenter.default.publisher(for: .badgeEarned)
      .receive(on: DispatchQueue.main)
      .compactMap { $0.object as? Badge }
      .sink { [weak self] badge in
        self?.handleNewBadge(badge)
      }
      .store(in: &cancellables)
  }

  func load() async {
    isLoading = true
    defer { isLoading = false }

    earnedBadges = await badgeService.earnedBadges()
    inProgressBadges = await badgeService.inProgressBadges()
    lockedBadges = await badgeService.lockedBadges()
  }

  func selectBadge(_ badge: Badge) {
    selectedBadge = badge
    showBadgeDetail = true
  }

  var totalBadgesCount: Int {
    BadgeCatalog.all.count
  }

  var earnedCount: Int {
    earnedBadges.count
  }

  var progressSummary: String {
    "\(earnedCount)/\(totalBadgesCount) badges earned"
  }

  // MARK: - Private

  private func handleNewBadge(_ badge: Badge) {
    newlyEarnedBadgeIDs.insert(badge.id)
    Task {
      await load()
    }
    // Clear animation flag after delay
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
      self?.newlyEarnedBadgeIDs.remove(badge.id)
    }
  }
}
