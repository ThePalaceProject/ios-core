extension Date {

  /// Returns the date formatted as "October 19, 2021".
  var monthDayYearString: String {
    let dateFormatter = DateFormatter()
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.dateFormat = "MMMM d, yyyy"
    return dateFormatter.string(from: self)
  }

  func timeUntil() -> (value: Int, unit: String) {
    let now = Date()
    let calendar = Calendar.current
    let components = calendar.dateComponents([.day, .hour, .minute], from: now, to: self)

    if let days = components.day, days > 0 {
      switch days {
      case 1: return (1, "day")
      case 2..<7: return (days, "days")
      case 7..<30: return (days / 7, days / 7 == 1 ? "week" : "weeks")
      default: return (days / 30, days / 30 == 1 ? "month" : "months")
      }
    }

    if let hours = components.hour, hours > 0 {
      return (hours, hours == 1 ? "hour" : "hours")
    }

    if let minutes = components.minute, minutes > 0 {
      return (minutes, minutes == 1 ? "minute" : "minutes")
    }

    return (0, "expired")
  }
}
