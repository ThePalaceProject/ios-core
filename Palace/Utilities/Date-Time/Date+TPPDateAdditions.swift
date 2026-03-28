// Swift replacement for NSDate+NYPLDateAdditions.m
//
// Date parsing and formatting extensions for RFC 3339 and ISO 8601.

import Foundation

extension Date {

  /// Parses an RFC 3339 date string. Handles optional fractional seconds.
  static func dateWithRFC3339String(_ string: String?) -> Date? {
    guard let string = string else { return nil }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)

    formatter.dateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ssX5"
    if let date = formatter.date(from: string) {
      return date
    }

    formatter.dateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ss.SSSSSSX5"
    return formatter.date(from: string)
  }

  /// Parses an ISO 8601 full-date string (e.g. "2020-01-22").
  /// Falls back to year-only format (e.g. "2020").
  static func dateWithISO8601DateString(_ string: String?) -> Date? {
    guard let string = string else { return nil }

    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withFullDate]
    isoFormatter.timeZone = TimeZone(secondsFromGMT: 0)

    if let date = isoFormatter.date(from: string) {
      return date
    }

    let yearFormatter = DateFormatter()
    yearFormatter.dateFormat = "yyyy"
    return yearFormatter.date(from: string)
  }

  /// Returns an RFC 3339 formatted string representation.
  func rfc3339String() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'"
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: self)
  }

  /// Returns the date's components in UTC.
  func utcComponents() -> DateComponents {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let allComponents: Set<Calendar.Component> = [
      .era, .year, .month, .day, .hour, .minute, .second, .nanosecond,
      .weekday, .weekdayOrdinal, .quarter, .weekOfMonth, .weekOfYear,
      .yearForWeekOfYear, .calendar, .timeZone
    ]
    return calendar.dateComponents(allComponents, from: self)
  }
}

// NOTE: NSDate ObjC compatibility methods (dateWithRFC3339String:, RFC3339String,
// dateWithISO8601DateString:, UTCComponents) are provided by the ObjC
// NSDate+NYPLDateAdditions category. This Swift extension adds Date-native
// equivalents only.
