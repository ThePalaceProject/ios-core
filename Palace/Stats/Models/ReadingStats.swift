import Foundation

/// Time period for filtering reading statistics.
enum TimePeriod: String, CaseIterable, Identifiable {
  case week = "Week"
  case month = "Month"
  case year = "Year"
  case all = "All Time"

  var id: String { rawValue }

  func startDate(from now: Date = Date()) -> Date? {
    let calendar = Calendar.current
    switch self {
    case .week:
      return calendar.date(byAdding: .day, value: -7, to: now)
    case .month:
      return calendar.date(byAdding: .month, value: -1, to: now)
    case .year:
      return calendar.date(byAdding: .year, value: -1, to: now)
    case .all:
      return nil
    }
  }
}

/// A single data point for charts.
struct ChartDataPoint: Identifiable, Equatable {
  let id = UUID()
  let label: String
  let date: Date
  let value: Double
  let format: ReadingFormat?

  static func == (lhs: ChartDataPoint, rhs: ChartDataPoint) -> Bool {
    lhs.label == rhs.label && lhs.date == rhs.date && lhs.value == rhs.value && lhs.format == rhs.format
  }
}

/// Aggregated reading statistics computed from session history.
struct ReadingStats: Equatable {
  var totalBooksFinished: Int = 0
  var totalReadingMinutes: Double = 0
  var totalPagesRead: Int = 0
  var totalAudiobookMinutes: Double = 0
  var booksByGenre: [String: Int] = [:]
  var averageSessionMinutes: Double = 0
  var sessionsCount: Int = 0
  var uniqueLibraries: Set<String> = []

  var totalReadingHours: Double {
    totalReadingMinutes / 60.0
  }

  var formattedTotalTime: String {
    let hours = Int(totalReadingMinutes / 60)
    let mins = Int(totalReadingMinutes.truncatingRemainder(dividingBy: 60))
    if hours > 0 {
      return "\(hours)h \(mins)m"
    }
    return "\(mins)m"
  }
}

/// Tracks which books the user has finished.
struct BookCompletion: Codable, Equatable {
  let bookID: String
  let bookTitle: String
  let format: ReadingFormat
  let genres: [String]
  let completedDate: Date
  let libraryAccount: String?
}
