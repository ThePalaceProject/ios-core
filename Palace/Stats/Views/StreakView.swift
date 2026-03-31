import SwiftUI

/// Detailed streak view with a GitHub-style calendar heatmap.
@available(iOS 16.0, *)
struct StreakView: View {
  let streak: ReadingStreak
  @State private var selectedDate: Date?

  private let calendar = Calendar.current
  private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)
  private let weeksToShow = 16

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      streakHeader
      calendarHeatmap
      legend
    }
    .padding()
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Reading streak calendar")
  }

  @ViewBuilder
  private var streakHeader: some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Reading Streak")
          .font(.headline)
          .accessibilityAddTraits(.isHeader)

        if streak.currentStreakDays > 0 {
          HStack(spacing: 4) {
            Image(systemName: "flame.fill")
              .foregroundStyle(.orange)
            Text("\(streak.currentStreakDays) day\(streak.currentStreakDays == 1 ? "" : "s")")
              .font(.title2)
              .fontWeight(.bold)
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel("Current streak: \(streak.currentStreakDays) days")
        } else {
          Text("No active streak")
            .font(.title3)
            .foregroundStyle(.secondary)
        }
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 4) {
        Text("Best")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("\(streak.longestStreakDays)")
          .font(.title)
          .fontWeight(.bold)
          .foregroundStyle(.orange)
        Text("days")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Best streak: \(streak.longestStreakDays) days")
    }
  }

  @ViewBuilder
  private var calendarHeatmap: some View {
    VStack(alignment: .leading, spacing: 2) {
      // Day labels
      HStack(spacing: 0) {
        ForEach(["S", "M", "T", "W", "T", "F", "S"], id: \.self) { day in
          Text(day)
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }
      }

      LazyVGrid(columns: columns, spacing: 3) {
        ForEach(heatmapDates, id: \.self) { date in
          heatmapCell(for: date)
        }
      }
    }
  }

  @ViewBuilder
  private func heatmapCell(for date: Date) -> some View {
    let isActive = streak.wasActiveOn(date)
    let isToday = calendar.isDateInToday(date)
    let isFuture = date > Date()

    RoundedRectangle(cornerRadius: 2)
      .fill(cellColor(isActive: isActive, isFuture: isFuture))
      .aspectRatio(1, contentMode: .fit)
      .overlay {
        if isToday {
          RoundedRectangle(cornerRadius: 2)
            .strokeBorder(Color.primary.opacity(0.3), lineWidth: 1)
        }
      }
      .accessibilityLabel(cellAccessibilityLabel(date: date, isActive: isActive))
  }

  private func cellColor(isActive: Bool, isFuture: Bool) -> Color {
    if isFuture {
      return Color.clear
    }
    if isActive {
      return Color.green
    }
    return Color.secondary.opacity(0.15)
  }

  @ViewBuilder
  private var legend: some View {
    HStack(spacing: 4) {
      Text("Less")
        .font(.system(size: 9))
        .foregroundStyle(.secondary)

      RoundedRectangle(cornerRadius: 2)
        .fill(Color.secondary.opacity(0.15))
        .frame(width: 12, height: 12)

      RoundedRectangle(cornerRadius: 2)
        .fill(Color.green)
        .frame(width: 12, height: 12)

      Text("More")
        .font(.system(size: 9))
        .foregroundStyle(.secondary)

      Spacer()

      Text("\(streak.activeDates.count) active days")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Heatmap Data

  private var heatmapDates: [Date] {
    let today = calendar.startOfDay(for: Date())
    let totalDays = weeksToShow * 7
    // Start from the beginning of the grid (Sunday of the earliest week)
    guard let startDate = calendar.date(byAdding: .day, value: -(totalDays - 1), to: today) else { return [] }
    let weekday = calendar.component(.weekday, from: startDate)
    let daysToSubtract = weekday - 1
    guard let gridStart = calendar.date(byAdding: .day, value: -daysToSubtract, to: startDate) else { return [] }

    var dates: [Date] = []
    var current = gridStart
    while current <= today {
      dates.append(current)
      guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
      current = next
    }
    return dates
  }

  private func cellAccessibilityLabel(date: Date, isActive: Bool) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    let dateString = formatter.string(from: date)
    return isActive ? "Read on \(dateString)" : "No reading on \(dateString)"
  }
}

#Preview {
  let streak = ReadingStreak(
    currentStreakStartDate: Calendar.current.date(byAdding: .day, value: -4, to: Date()),
    currentStreakDays: 5,
    longestStreakDays: 12,
    lastActiveDate: Date(),
    activeDates: Set((0..<5).compactMap { offset in
      Calendar.current.date(byAdding: .day, value: -offset, to: Date())
        .map { ReadingStreak.dateKey(for: $0) }
    })
  )
  ScrollView {
    StreakView(streak: streak)
      .padding()
  }
}
