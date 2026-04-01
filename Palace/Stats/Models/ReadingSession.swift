import Foundation

/// The format of media being consumed during a reading session.
enum ReadingFormat: String, Codable, CaseIterable {
  case epub
  case pdf
  case audiobook
}

/// A single reading session, representing a contiguous period of reading or listening.
struct ReadingSession: Codable, Identifiable, Equatable {
  let id: UUID
  let bookID: String
  let bookTitle: String
  let format: ReadingFormat
  let startTime: Date
  var endTime: Date?
  var pagesRead: Int
  var minutesListened: Double
  var genres: [String]
  var libraryAccount: String?

  var duration: TimeInterval {
    guard let endTime else { return 0 }
    return endTime.timeIntervalSince(startTime)
  }

  var durationMinutes: Double {
    duration / 60.0
  }

  var isActive: Bool {
    endTime == nil
  }

  init(
    id: UUID = UUID(),
    bookID: String,
    bookTitle: String,
    format: ReadingFormat,
    startTime: Date = Date(),
    endTime: Date? = nil,
    pagesRead: Int = 0,
    minutesListened: Double = 0,
    genres: [String] = [],
    libraryAccount: String? = nil
  ) {
    self.id = id
    self.bookID = bookID
    self.bookTitle = bookTitle
    self.format = format
    self.startTime = startTime
    self.endTime = endTime
    self.pagesRead = pagesRead
    self.minutesListened = minutesListened
    self.genres = genres
    self.libraryAccount = libraryAccount
  }
}
