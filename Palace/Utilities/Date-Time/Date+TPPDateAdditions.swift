import Foundation

extension NSDate {

  /// Parses an RFC 3339 date string. Handles fractional seconds but ignores them.
  @objc(dateWithRFC3339String:)
  convenience init?(rfc3339String string: String?) {
    guard let string = string else { return nil }

    let dateFormatter = DateFormatter()
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)

    dateFormatter.dateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ssXXXXX"
    if let date = dateFormatter.date(from: string) {
      self.init(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate)
      return
    }

    dateFormatter.dateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ss.SSSSSSXXXXX"
    if let date = dateFormatter.date(from: string) {
      self.init(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate)
      return
    }

    return nil
  }

  /// Parses an ISO 8601 full date string (e.g. "2020-01-22").
  @objc(dateWithISO8601DateString:)
  convenience init?(iso8601DateString string: String?) {
    guard let string = string else { return nil }

    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withFullDate]
    isoFormatter.timeZone = TimeZone(secondsFromGMT: 0)

    if let date = isoFormatter.date(from: string) {
      self.init(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate)
      return
    }

    // Fallback: try year-only format
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy"
    if let date = dateFormatter.date(from: string) {
      self.init(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate)
      return
    }

    return nil
  }

  /// Returns the date formatted as an RFC 3339 string.
  @objc(RFC3339String)
  func rfc3339String() -> String {
    let dateFormatter = DateFormatter()
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.dateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'"
    dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
    return dateFormatter.string(from: self as Date)
  }

  /// Returns the UTC date components for the receiver.
  @objc(UTCComponents)
  func utcComponents() -> DateComponents {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.dateComponents(
      [.era, .year, .month, .day, .hour, .minute, .second, .nanosecond,
       .weekday, .weekdayOrdinal, .quarter, .weekOfMonth, .weekOfYear,
       .yearForWeekOfYear, .calendar, .timeZone],
      from: self as Date
    )
  }
}
