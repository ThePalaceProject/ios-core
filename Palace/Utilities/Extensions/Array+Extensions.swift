extension Array {
  subscript(safe index: Int) -> Element? {
    get {
      return indices.contains(index) ? self[index] : nil
    }
    set {
      if indices.contains(index), let value = newValue {
        self[index] = value
      }
    }
  }
}
