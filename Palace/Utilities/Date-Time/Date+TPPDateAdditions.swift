import Foundation

extension NSDate {

  private static let rfc3339Formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }()

  /// Parses an RFC 3339 date string. Correctly handles fractional seconds but ignores them.
  @objc static func date(withRFC3339String string: String?) -> NSDate? {
    guard let string = string else { return nil }

    let formatter = rfc3339Formatter
    formatter.dateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ssX5"
    if let date = formatter.date(from: string) {
      return date as NSDate
    }

    formatter.dateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ss.SSSSSSX5"
    return formatter.date(from: string) as NSDate?
  }

  /// Parses an ISO-8601 full date string with no time info, e.g. "2020-01-22".
  @objc static func date(withISO8601DateString string: String?) -> NSDate? {
    guard let string = string else { return nil }

    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withFullDate]
    isoFormatter.timeZone = TimeZone(secondsFromGMT: 0)

    if let date = isoFormatter.date(from: string) {
      return date as NSDate
    }

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy"
    return dateFormatter.date(from: string) as NSDate?
  }

  @objc func rfc3339String() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'"
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: self as Date)
  }

  @objc func utcComponents() -> DateComponents {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.dateComponents(
      [.era, .year, .month, .day, .hour, .minute, .second, .weekday, .weekdayOrdinal,
       .quarter, .weekOfMonth, .weekOfYear, .yearForWeekOfYear, .nanosecond, .calendar, .timeZone],
      from: self as Date
    )
  }
}
