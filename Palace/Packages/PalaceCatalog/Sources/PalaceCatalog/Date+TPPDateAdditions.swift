import Foundation
import os

public extension NSDate {

  private static let rfc3339FormatterNoFraction: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ssX5"
    return formatter
  }()

  private static let rfc3339FormatterWithFraction: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ss.SSSSSSX5"
    return formatter
  }()

  /// ISO8601DateFormatter is not Sendable, so the shared instance is read
  /// under a lock.
  private static let iso8601FullDateFormatter = OSAllocatedUnfairLock(uncheckedState: {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }())

  /// Locale and time zone stay unset: a formatter left at the defaults reads
  /// the current default time zone on each parse, as a per-call one did.
  private static let yearOnlyFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy"
    return formatter
  }()

  private static let rfc3339OutputFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'"
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }()

  /// Parses an RFC 3339 date string. Correctly handles fractional seconds but ignores them.
  @objc public static func date(withRFC3339String string: String?) -> NSDate? {
    guard let string = string else { return nil }

    if let date = rfc3339FormatterNoFraction.date(from: string) {
      return date as NSDate
    }

    return rfc3339FormatterWithFraction.date(from: string) as NSDate?
  }

  /// Parses an ISO-8601 full date string with no time info, e.g. "2020-01-22".
  @objc public static func date(withISO8601DateString string: String?) -> NSDate? {
    guard let string = string else { return nil }

    if let date = iso8601FullDateFormatter.withLockUnchecked({ $0.date(from: string) }) {
      return date as NSDate
    }

    return yearOnlyFormatter.date(from: string) as NSDate?
  }

  @objc public func rfc3339String() -> String {
    NSDate.rfc3339OutputFormatter.string(from: self as Date)
  }

  @objc public func utcComponents() -> DateComponents {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    return calendar.dateComponents(
      [.era, .year, .month, .day, .hour, .minute, .second, .weekday, .weekdayOrdinal,
       .quarter, .weekOfMonth, .weekOfYear, .yearForWeekOfYear, .nanosecond, .calendar, .timeZone],
      from: self as Date
    )
  }
}
