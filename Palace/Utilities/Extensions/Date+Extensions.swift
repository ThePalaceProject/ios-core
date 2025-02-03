extension Date {

  /// Returns the date formatted as "October 19, 2021".
  var monthDayYearString: String {
    let dateFormatter = DateFormatter()
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.dateFormat = "MMMM d, yyyy"
    return dateFormatter.string(from: self)
  }

}
