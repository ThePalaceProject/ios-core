extension Int {
  func ordinal() -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .ordinal
    return formatter.string(from: NSNumber(value: self)) ?? "\(self)"
  }
}
