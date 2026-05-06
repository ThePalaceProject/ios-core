import Foundation

/// A lightweight tracker that reader and audiobook view controllers can call
/// to record reading sessions. Does NOT modify existing reader code; provides
/// the integration hook for stats tracking.
///
/// Usage from a reader VC:
///   tracker.startSession(bookID: "123", bookTitle: "Moby Dick", format: .epub)
///   tracker.recordPageTurn()
///   tracker.endSession()
@MainActor
final class ReadingSessionTracker {
  private let statsService: ReadingStatsServiceProtocol
  private let badgeService: BadgeServiceProtocol

  private var activeSession: ReadingSession?
  private var pageCount: Int = 0

  init(statsService: ReadingStatsServiceProtocol, badgeService: BadgeServiceProtocol) {
    self.statsService = statsService
    self.badgeService = badgeService
  }

  /// Starts tracking a new reading session. If a session is already active, it is ended first.
  func startSession(
    bookID: String,
    bookTitle: String,
    format: ReadingFormat,
    genres: [String] = [],
    libraryAccount: String? = nil
  ) {
    if activeSession != nil {
      endSession()
    }
    pageCount = 0
    activeSession = ReadingSession(
      bookID: bookID,
      bookTitle: bookTitle,
      format: format,
      genres: genres,
      libraryAccount: libraryAccount
    )
  }

  /// Records a page turn in the current session.
  func recordPageTurn() {
    pageCount += 1
  }

  /// Ends the active session and persists it. Also triggers badge evaluation.
  func endSession() {
    guard var session = activeSession else { return }
    session.endTime = Date()
    session.pagesRead = pageCount

    if session.format == .audiobook {
      session.minutesListened = session.durationMinutes
    }

    activeSession = nil
    pageCount = 0

    // Only record sessions longer than 10 seconds to filter accidental opens
    guard session.duration >= 10 else { return }

    Task {
      await statsService.recordSession(session)
      await badgeService.refresh()
    }
  }

  /// Records that the user has finished a book.
  func recordBookFinished(
    bookID: String,
    bookTitle: String,
    format: ReadingFormat,
    genres: [String] = [],
    libraryAccount: String? = nil
  ) {
    let completion = BookCompletion(
      bookID: bookID,
      bookTitle: bookTitle,
      format: format,
      genres: genres,
      completedDate: Date(),
      libraryAccount: libraryAccount
    )
    Task {
      await statsService.recordBookCompletion(completion)
      await badgeService.refresh()
    }
  }

  /// Whether a session is currently being tracked.
  var isTracking: Bool {
    activeSession != nil
  }

  /// The book ID of the currently active session, if any.
  var activeBookID: String? {
    activeSession?.bookID
  }
}
